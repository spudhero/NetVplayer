import Combine
import Foundation
import MediaServerEngine
import Models
import Storage

@MainActor
final class MediaServerAccountModel: ObservableObject {
  enum SessionState: Equatable {
    case newAccount, signedOut, saved, checking, signedIn, expired, unavailable
  }
  @Published private(set) var accounts: [MediaServerConfiguration] = []
  @Published private(set) var selectedID: UUID?
  @Published var kind = MediaServerKind.jellyfin
  @Published var name = ""
  @Published var server = ""
  @Published var username = ""
  @Published var password = ""
  @Published var allowsHTTP = false
  @Published var reauthenticating = false
  @Published private(set) var state = SessionState.newAccount
  @Published private(set) var hasStoredToken = false
  @Published private(set) var storedLogins = Set<UUID>()
  @Published private(set) var busy = false
  @Published private(set) var isLoggingOut = false
  @Published private(set) var status: String?
  @Published private(set) var statusRole = AppSemanticColorRole.secondaryText
  private let store: MediaServerStore
  private let transport: MediaServerTransport
  private let invalidate: @Sendable (UUID) async -> Void
  private var generation = UUID()
  private var task: Task<Void, Never>?

  init(
    store: MediaServerStore = .shared, transport: MediaServerTransport = .init(),
    invalidate: @escaping @Sendable (UUID) async -> Void = {
      await MediaServerRuntime.shared.invalidate($0)
    }
  ) {
    self.store = store
    self.transport = transport
    self.invalidate = invalidate
  }
  var selected: MediaServerConfiguration? { accounts.first { $0.id == selectedID } }
  var nameChanged: Bool {
    selected.map { $0.name != name.trimmingCharacters(in: .whitespacesAndNewlines) } ?? false
  }
  var serverChanged: Bool {
    guard let selected else { return false }
    var candidate = selected
    candidate.kind = kind
    candidate.server = server
    candidate.allowsHTTP = allowsHTTP
    guard let normalized = try? candidate.validated() else { return true }
    return normalized.server != selected.server || normalized.kind != selected.kind
  }
  var showsLoginFields: Bool {
    !hasStoredToken || state == .expired || reauthenticating || serverChanged
  }
  var canConnect: Bool {
    !busy && !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (kind == .plex ? !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  func load(checkConnection: Bool = true) {
    accounts = store.load()
    storedLogins = Set(accounts.filter { (try? store.token(for: $0)) != nil }.map(\.id))
    select(selectedID ?? accounts.first?.id, checkConnection: checkConnection)
  }
  func select(_ id: UUID?, checkConnection: Bool = true) {
    stop()
    generation = UUID()
    busy = false
    isLoggingOut = false
    selectedID = id
    status = nil
    reauthenticating = false
    guard let account = selected else {
      kind = .jellyfin
      name = ""
      server = ""
      username = ""
      allowsHTTP = false
      hasStoredToken = false
      state = .newAccount
      return
    }
    kind = account.kind
    name = account.name
    server = account.server
    username = account.username ?? ""
    allowsHTTP = account.allowsHTTP
    hasStoredToken = (try? store.token(for: account)) != nil
    state = hasStoredToken ? .saved : .signedOut
    if checkConnection && hasStoredToken { check() }
  }
  func stop() {
    task?.cancel()
    password = ""
  }

  func saveName(onSaved: () -> Void) {
    guard var account = selected, !busy, !serverChanged else { return }
    account.name = name
    do {
      account = try account.validated()
      var saved = store.load()
      guard let index = saved.firstIndex(where: { $0.id == account.id }) else { return }
      saved[index] = account
      try store.save(saved)
      accounts = saved
      name = account.name
      statusRole = .success
      status = L10n.text("账号名称已保存。")
      onSaved()
    } catch {
      statusRole = .danger
      status = error.localizedDescription
    }
  }

  func check() {
    guard let account = selected, !busy, !serverChanged else { return }
    guard let token = try? store.token(for: account) else {
      hasStoredToken = false
      storedLogins.remove(account.id)
      state = .signedOut
      return
    }
    let request = UUID()
    generation = request
    state = .checking
    busy = true
    status = nil
    let observation = ServiceConnectionObservations.shared.begin(store.connectionObservationScope(account))
    task = Task { @MainActor in
      defer { if generation == request { busy = false } }
      do {
        let client = try MediaServerClient(account: account, token: token, transport: transport)
        let user = try await client.sessionUser()
        try Task.checkCancellation()
        guard generation == request else { return }
        var saved = store.load()
        guard let index = saved.firstIndex(of: account) else {
          state = .saved
          return
        }
        if let value = user.Name?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
          username = value
          var updated = account
          updated.username = value
          if updated != account {
            saved[index] = updated
            try store.save(saved)
            accounts = saved
          }
        }
        state = .signedIn
        ServiceConnectionObservations.shared.finish(observation, state: .available)
      } catch {
        guard generation == request else { return }
        if Task.isCancelled || error is CancellationError {
          state = .saved
        } else if let failure = error as? MediaServerError, case .authentication = failure {
          state = .expired
        } else {
          state = .unavailable
        }
        if !TaskDiagnosticIssue.isCancellation(error), store.load().contains(account) {
          ServiceConnectionObservations.shared.finish(observation, state: ServiceConnectionObservations.failure(error))
        }
      }
    }
  }

  func connect(onSaved: @escaping () -> Void) {
    guard canConnect else { return }
    busy = true
    isLoggingOut = false
    status = nil
    statusRole = .secondaryText
    let request = UUID()
    generation = request
    var candidate = selected ?? .init()
    candidate.name = name
    candidate.kind = kind
    candidate.server = server
    candidate.allowsHTTP = allowsHTTP
    let accountToConnect = candidate
    let previousAccount = selected
    let user = username
    let secret = password
    task = Task { @MainActor in
      defer {
        if generation == request {
          busy = false
          password = ""
        }
      }
      do {
        let client = try MediaServerClient(account: accountToConnect, transport: transport)
        let (account, token) = try await client.authenticate(username: user, password: secret)
        try Task.checkCancellation()
        guard generation == request else { return }
        let previousToken = previousAccount.flatMap { try? store.token(for: $0) }
        try store.saveToken(token, for: account)
        var updated = store.load()
        updated.removeAll { $0.id == account.id }
        updated.append(account)
        do { try store.save(updated) } catch {
          try? store.removeToken(for: account)
          if let previousToken, let previousAccount {
            try? store.saveToken(previousToken, for: previousAccount)
          }
          throw error
        }
        let observation = ServiceConnectionObservations.shared.begin(store.connectionObservationScope(account))
        await invalidate(account.id)
        try Task.checkCancellation()
        guard generation == request else { return }
        accounts = updated
        selectedID = account.id
        username = account.username ?? user
        name = account.name
        server = account.server
        hasStoredToken = true
        storedLogins.insert(account.id)
        state = .signedIn
        reauthenticating = false
        if store.load().contains(account) {
          ServiceConnectionObservations.shared.finish(observation, state: .available)
        }
        statusRole = .success
        status = L10n.text("媒体服务器已连接，可在影视来源中选择。")
        onSaved()
      } catch {
        guard generation == request else { return }
        statusRole = Task.isCancelled || error is CancellationError ? .secondaryText : .danger
        status =
          Task.isCancelled || error is CancellationError
          ? L10n.text("连接已取消，可重新验证。") : error.localizedDescription
      }
    }
  }

  func logout() {
    guard let account = selected, !busy else { return }
    busy = true
    isLoggingOut = true
    status = nil
    let request = UUID()
    generation = request
    task = Task { @MainActor in
      defer {
        if generation == request {
          busy = false
          isLoggingOut = false
          password = ""
        }
      }
      do {
        let token = try? store.token(for: account)
        try store.removeToken(for: account)
        hasStoredToken = false
        storedLogins.remove(account.id)
        state = .signedOut
        reauthenticating = false
        await invalidate(account.id)
        if let token,
          let client = try? MediaServerClient(account: account, token: token, transport: transport)
        {
          try? await client.logout()
        }
        guard generation == request else { return }
        statusRole = .success
        status = L10n.text("账号已退出，服务器配置已保留。")
      } catch {
        guard generation == request else { return }
        statusRole = .danger
        status = error.localizedDescription
      }
    }
  }
}
