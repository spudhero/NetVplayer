import ProxyServer
import AppKit
import SwiftUI
import ConfigEngine
import CryptoKit
import Foundation
import Models
import PlayerEngine
import SpiderEngine
import Storage

/// Opt-in acceptance run inside the installed development app. Uses the same
/// AppState content and player operations as the normal windows; no mock data.
@MainActor
enum DevelopmentAndroidAppAudit {
    private static var task: Task<Void, Never>?
    private static var timedOut = false
    private static var auditWindow: NSWindow?

    struct Plan: Decodable {
        enum HomeRevisit: String, Decodable { case cached, refresh, restartHelper }
        let config: String
        let output: String
        var only: [String]?
        var sampleCount: Int?
        var sampleOffset: Int?
        var sampleVodID: String?
        var episodeIndex: Int?
        var requestedPlayFlag: String?
        var categoryID: String?
        var posterTransportProbe: Bool?
        var categoryProbeID: String?
        var categoryProbeWarmup: Bool?
        var detailProbeID: String?
        var exactPlayback: DevelopmentAndroidReplayAudit.Selection?
        var exactPlaybackBatch: [DevelopmentAndroidReplayAudit.Selection]?
        /// One original preparation through production playHistory, using a
        /// byte-for-byte copy of history saved by a previous accepted activity.
        var resumeFromSavedHistory: Bool?
        var expectedHistorySHA256: String?
        /// Exact replays default to one submitted playback, without app recovery probes.
        var singlePlaybackAttempt: Bool?
        var usesSinglePlaybackAttempt: Bool { singlePlaybackAttempt ?? (exactPlayback != nil || exactPlaybackBatch != nil) }
        var searchKeyword: String?
        var playbackSeconds: Int?
        var observeFullPlaybackWindow: Bool?
        /// Total wait for an uninterrupted window, including loading and buffering.
        var playbackObservationTimeoutSeconds: Int?
        var requestedQuality: String?
        var requestedMagnetFileIndex: Int?
        var attachmentContract: DevelopmentAndroidAttachmentAudit.Plan?
        var playbackContract: DevelopmentAndroidPlaybackContractAudit.Plan?
        var inspectionHoldSeconds: Int?
        var samplingSeed: String?
        var allSelectedSamples: Bool?
        var inventoryOnly: Bool?
        var homeOnly: Bool?
        var quitAfterAudit: Bool?
        var providerExecutionPreference: ProviderExecutionPreference?
        var expectedConfigSHA256: String?
        var requiredOutput: DevelopmentAndroidAuditContract.RequiredOutput?
        var homeRevisits: [HomeRevisit]?
        var accountFree: Bool?
        var componentInstallDirectory: String?
        var componentRollback: Bool?
        /// Repeat the same UI operations without retiring the App or its helper.
        var performanceReplays: Int?
        var performanceReplayCount: Int { min(3, max(0, performanceReplays ?? 0)) }
    }

    static var current: Plan? {
        guard let index = CommandLine.arguments.firstIndex(of: "--android-provider-audit"),
              CommandLine.arguments.indices.contains(index + 1),
              let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])),
              let plan = try? JSONDecoder().decode(Plan.self, from: data),
              plan.config.hasPrefix("/"), plan.output.hasPrefix("/") else { return nil }
        return plan
    }

    static func selectRequestedPlayFlag(_ requestedFlag: String?, state: AppState) -> Bool {
        guard let requestedFlag else { return true }
        guard state.playFlags.contains(requestedFlag) else { return false }
        state.selectPlayFlag(requestedFlag)
        return state.selectedPlayFlag == requestedFlag
    }

    static func makeState(_ plan: Plan, installedProviderBootstrap: ProviderRuntimeBootstrap? = nil) -> AppState {
        let storage = StorageManager(storageDirectory: URL(fileURLWithPath: plan.output, isDirectory: true)
            .appendingPathComponent("app-state", isDirectory: true))
        let preferences = UserPreferences.shared.makeIsolatedSnapshot()
        if let preference = plan.providerExecutionPreference { preferences.providerExecutionPreference = preference }
        // A persisted UI selection must not silently warm another source before
        // the requested first source is observed.
        preferences.currentVodSiteKey = plan.only?.first ?? ""
        // Read active packages through the normal bundle trust keys. Runtime
        // state is isolated; signed sandboxes use a fresh session beneath their
        // existing state entitlement. Startup and readiness cannot download.
        let bootstrap = installedProviderBootstrap ?? ProviderRuntimeBootstrap.makeDefault(
            stateDirectoryRootURL: URL(fileURLWithPath: plan.output, isDirectory: true)
                .appendingPathComponent("provider-state", isDirectory: true), installedOnly: true)
        return AppState(loadDefaultConfig: false, startProxyServer: true, startProviderRuntime: bootstrap != nil,
            storageManager: storage, userPreferences: preferences, providerRuntimeBootstrap: bootstrap,
            providerRuntimeStartupOverride: {
                guard let bootstrap else { return false }
                return !(await bootstrap.installedManifests()).isEmpty
            },
            catalogRepository: CatalogRepository())
    }

    static func start(_ plan: Plan, state: AppState) {
        task?.cancel()
        task = Task {
            // A restored closed scene can run the coordinator without any view.
            // Host the production container only for explicit audits with no
            // visible window, so playback still uses an actual AppKit surface.
            try? await Task.sleep(for: .seconds(1))
            if !NSApp.windows.contains(where: { $0.isVisible && $0.contentView != nil }) {
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
                    styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "NetVplayer Android Test"
                window.contentView = NSHostingView(rootView: MainContainerView().environmentObject(state))
                auditWindow = window
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            await run(plan, state: state)
            if plan.quitAfterAudit == true {
                // Finish asynchronous service cleanup before entering AppKit's
                // synchronous termination path from this audit task.
                let retirementStart = ProcessInfo.processInfo.systemUptime
                retirement(plan, status: "started", elapsed: 0)
                let completed = await AppStartup.shared.terminate().value
                retirement(plan, status: completed ? "complete" : "failed",
                    elapsed: DevelopmentAndroidSampling.milliseconds(since: retirementStart))
                state.userPreferences.discardIsolatedSnapshot()
                UserPreferences.shared.discardIsolatedSnapshot()
                if completed { NSApplication.shared.terminate(nil) }
            }
        }
    }

    static func cancel() { task?.cancel() }

    static func run(_ plan: Plan, state: AppState) async {
        timedOut = false
        let previousAutomation = state.allowsAutomaticVodPlaybackActions
        let previousSearchFallback = state.allowsSearchFallbacks
        state.allowsAutomaticVodPlaybackActions = !plan.usesSinglePlaybackAttempt
        state.allowsSearchFallbacks = false
        defer {
            state.allowsAutomaticVodPlaybackActions = previousAutomation
            state.allowsSearchFallbacks = previousSearchFallback
        }
        let directory = URL(fileURLWithPath: plan.output, isDirectory: true)
        var ledger: [String: Any] = [
            "schema": 2, "status": "running", "started": Date().ISO8601Format(),
            "app_path": Bundle.main.bundlePath,
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "backend": CommandLine.arguments.contains("--android-provider-native-baseline") ? "native-baseline" : "emulated",
            "provider_execution_preference": state.activeProviderExecutionPreference.rawValue,
            "process_id": ProcessInfo.processInfo.processIdentifier,
            "sampling_method": plan.samplingSeed == nil ? "original_order" : "seeded_identity_hash_ranking",
            "all_selected_samples": plan.allSelectedSamples == true,
            "account_context": CommandLine.arguments.contains("--android-provider-account-free-audit")
                ? "empty_preferences_and_memory_credentials" : "isolated_snapshot_of_saved_mac_preferences",
            "android_account_equivalence_verified": false,
            "sites": [[String: Any]](),
            "audit_window_created": auditWindow != nil,
            "configuration_live_content_requested": false,
            "single_playback_attempt": plan.usesSinglePlaybackAttempt,
            "search_selection_fallback_allowed": state.allowsSearchFallbacks,
            "search_query_fallback_allowed": state.allowsSearchFallbacks,
            "visible_window_count": NSApp.windows.filter(\.isVisible).count,
            "method": "installed AppState content operations and libmpv playback; sampled timelines, not URL-only checks"
        ]
        if let seed = plan.samplingSeed { ledger["sampling_seed"] = seed }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let operationPlans = try DevelopmentAndroidReplayBatchAudit.plans(from: plan)
            if plan.exactPlaybackBatch != nil {
                ledger["batch_identity_count"] = operationPlans.count
                ledger["batch_preparation_limit"] = operationPlans.count * 2
            }
            if plan.resumeFromSavedHistory == true {
                guard plan.exactPlayback?.isValid == true, plan.usesSinglePlaybackAttempt,
                      plan.only?.count == 1, plan.performanceReplayCount == 0,
                      plan.playbackContract?.reopen != true,
                      let expected = plan.expectedHistorySHA256, expected.count == 64 else {
                    throw AuditError.failed("invalid_saved_history_replay")
                }
                let historyURL = directory.appendingPathComponent("app-state/history.json")
                guard let data = try? Data(contentsOf: historyURL), hash(data) == expected else {
                    throw AuditError.failed("saved_history_hash_mismatch")
                }
                ledger["saved_history_sha256"] = expected
                ledger["playback_entry"] = "production_saved_history"
            }
            if plan.componentInstallDirectory != nil || plan.componentRollback == true {
                guard let componentRoot = ProcessInfo.processInfo.environment["NETVPLAYER_ANDROID_COMPONENT_ROOT"],
                      componentRoot.hasPrefix("/private/tmp/") || componentRoot.hasPrefix("/tmp/") else {
                    throw AuditError.failed("component_acceptance_requires_isolated_storage")
                }
                if let source = plan.componentInstallDirectory {
                    await state.installAndroidRuntimeComponent(directory: URL(fileURLWithPath: source))
                } else { await state.rollbackAndroidRuntimeComponent() }
                if let error = state.androidRuntimeComponentError { throw AuditError.failed(error) }
                ledger["component_version"] = state.androidRuntimeComponentVersion
                ledger["component_previous_version"] = state.androidRuntimePreviousVersion
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: plan.config))
            let json = String(decoding: data, as: UTF8.self)
            ledger["config_sha256"] = hash(data)
            ledger["config_canonical_sha256"] = try DevelopmentAndroidLifecycleDiagnostics.canonicalJSONSHA256(data)
            if let expected = plan.expectedConfigSHA256, expected != hash(data) {
                throw AuditError.failed("frozen_configuration_hash_mismatch")
            }
            let configuredKeys = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["sites"]
                as? [[String: Any]])?.compactMap { $0["key"] as? String } ?? []
            if let requested = plan.only, requested.contains(where: { !configuredKeys.contains($0) }) {
                throw AuditError.failed("requested_site_missing_from_configuration")
            }
            let sourceOrder = DevelopmentAndroidAuditContract.sourceOrder(available: configuredKeys, requested: plan.only)
            let input = ResolvedVodInput(json: json,
                config: Config(url: "development-android-audit", home: sourceOrder.first ?? "", json: json),
                kind: .configuration, canonicalURL: "development-android-audit", initialResult: nil,
                usesCachedConfiguration: true)
            ledger["current_phase"] = "configuration"
            try write(ledger, directory: directory)
            // Installed signed providers must be registered before development
            // route selection, exactly as they are during normal app startup.
            let installedReady = await bounded(seconds: 120) {
                await state.providerRuntimeStartupTask?.value
            }
            guard installedReady else { throw AuditError.failed("installed_provider_registration_timeout") }
            ledger["installed_providers"] = state.providerRuntimeInstalled.map {
                ["provider_id": $0.manifest.providerID, "version": $0.manifest.version]
            }
            // A saved snapshot prevents background source refresh from changing
            // the requested route identities halfway through the acceptance run.
            let configStart = ProcessInfo.processInfo.systemUptime
            let configurationCompleted = await bounded(seconds: 120) {
                await state.loadConfig(url: input.canonicalURL, persistUserConfig: false,
                    waitForProviderRuntime: false, refreshCachedConfiguration: false,
                    includeLiveContent: false, preparedInput: input)
            }
            ledger["configuration_ms"] = DevelopmentAndroidSampling.milliseconds(since: configStart)
            guard configurationCompleted else { throw AuditError.failed("configuration_timeout") }
            guard state.isConfigLoaded else { throw AuditError.failed(state.configError ?? "configuration") }
            let sites = sourceOrder.compactMap { key in state.sites.first { $0.key == key } }
            ledger["requested_sites"] = sites.map { ["key": $0.key, "name": $0.name] }
            try write(ledger, directory: directory)
            for (index, site) in sites.enumerated() {
                if Task.isCancelled { break }
                ledger["current_site"] = site.key
                ledger["current_phase"] = "home"
                try write(ledger, directory: directory)
                print("[ANDROID_APP_AUDIT] site=\(site.key) phase=start")
                for (memberIndex, memberPlan) in operationPlans.enumerated() {
                  if plan.exactPlaybackBatch != nil && memberIndex > 0 && state.activeSite?.key != site.key {
                    throw AuditError.failed("batch_source_context_changed")
                  }
                  for replay in 0...memberPlan.performanceReplayCount {
                    let operationStart = ProcessInfo.processInfo.systemUptime
                    var result = await audit(site, plan: memberPlan, state: state, directory: directory,
                        useConfigurationHome: (memberIndex > 0 || (replay == 0 && index == 0)) && state.activeSite?.key == site.key)
                    if plan.exactPlaybackBatch != nil {
                        result["batch_index"] = memberIndex
                        result["batch_identity_count"] = operationPlans.count
                        if memberIndex > 0 { result["home_origin"] = "same_site_session" }
                    }
                    result["performance_round"] = replay
                    result["performance_condition"] = replay == 0 ? "first_pass" : "same_app_replay"
                    result["started_uptime"] = operationStart
                    result["finished_uptime"] = ProcessInfo.processInfo.systemUptime
                    var records = ledger["sites"] as? [[String: Any]] ?? []
                    records.append(result)
                    ledger["sites"] = records
                    try write(ledger, directory: directory)
                    print("[ANDROID_APP_AUDIT] site=\(site.key) replay=\(replay) status=\(result["status"] ?? "unknown")")
                    if result["status"] as? String == "stopped_user_action" {
                        await retire(state)
                        await DevelopmentAndroidSiteProvider.shutdownAll()
                        ledger["status"] = "stopped_user_action"
                        ledger["failure_stage"] = result["failure_stage"]
                        ledger["authentication_required"] = result["authentication_required"]
                        ledger["verification_required"] = result["verification_required"]
                        ledger["finished"] = Date().ISO8601Format()
                        try write(ledger, directory: directory)
                        return
                    }
                    if plan.exactPlaybackBatch != nil && !DevelopmentAndroidReplayBatchAudit.completed(result) {
                        await retire(state)
                        await DevelopmentAndroidSiteProvider.shutdownAll()
                        ledger["status"] = "batch_stopped"
                        ledger["failure_stage"] = "batch_member_failed"
                        ledger["batch_stopped_index"] = memberIndex
                        ledger["finished"] = Date().ISO8601Format()
                        try write(ledger, directory: directory)
                        return
                    }
                    if timedOut || Task.isCancelled { break }
                  }
                  if timedOut || Task.isCancelled { break }
                }
                if plan.categoryProbeWarmup == true || plan.detailProbeID != nil {
                    // Let a read-only observer finish restoring and writing its
                    // evidence before retiring the helper it observed.
                    try? await Task.sleep(for: .seconds(3))
                }
                await retire(state)
                await DevelopmentAndroidSiteProvider.shutdownAll()
                if timedOut {
                    // A timed-out AppState operation may still be retiring.
                    // End this process's run; resume remaining sites in a fresh app.
                    ledger["status"] = "aborted_timeout"
                    ledger["finished"] = Date().ISO8601Format()
                    try write(ledger, directory: directory)
                    return
                }
            }
            ledger["status"] = Task.isCancelled ? "cancelled" : "complete"
            ledger["finished"] = Date().ISO8601Format()
            ledger.removeValue(forKey: "current_phase")
            try write(ledger, directory: directory)
        } catch {
            ledger["status"] = "audit_error"
            ledger["error"] = safe(String(describing: error))
            try? write(ledger, directory: directory)
            print("[ANDROID_APP_AUDIT] failed \(safe(String(describing: error)))")
        }
    }

    private static func audit(_ site: Site, plan: Plan, state: AppState, directory: URL,
                              useConfigurationHome: Bool) async -> [String: Any] {
        let started = Date()
        var record: [String: Any] = ["key": site.key, "name": site.name,
            "status": "failed", "api": site.api.hasPrefix("csp_") ? site.api : "javascript",
            "started": started.ISO8601Format(), "attempts": [[String: Any]]()]
        let developmentRegistered = await DevelopmentAndroidSiteProvider.isRegistered(site: site)
        record["execution_backend"] = await SpiderReplacementRegistry.shared.executionBackend(for: site).rawValue
        record["backend"] = developmentRegistered ? "android-emulated" : "existing-provider"
        if developmentRegistered {
            record["android_provider_sha256"] = await DevelopmentAndroidSiteProvider.effectiveProviderSHA256(site: site)
        } else if let installed = await SpiderReplacementRegistry.shared.nativeProvider(for: site) as? RemoteSiteContentProvider {
            record["backend"] = "installed-signed-provider"
            record["provider_id"] = installed.providerID
            record["provider_version"] = state.providerRuntimeInstalled.first {
                $0.manifest.providerID == installed.providerID
            }?.manifest.version
        }
        let isBrowsableFolder: (Vod) -> Bool = {
            site.allliveCategory(for: $0) != nil || (developmentRegistered && $0.isFolder)
        }
        defer { print("[ANDROID_APP_AUDIT] site=\(site.key) seconds=\(Int(Date().timeIntervalSince(started)))") }
        if let stopped = await stopForUserAction(state, record: record, directory: directory) { return stopped }
        if !useConfigurationHome || plan.detailProbeID != nil || plan.categoryProbeID != nil { await retire(state) }
        if let probeID = plan.detailProbeID {
            // Replay an exact previously observed opaque ID when an unrelated
            // catalogue request is unavailable. This is never a playback pass.
            record["diagnostic_only"] = true
            record["detail_id_sha256"] = hash(Data(probeID.utf8))
            guard developmentRegistered, !probeID.isEmpty, probeID.utf8.count <= 64 * 1024,
                  plan.categoryProbeID == nil else {
                record["failure_stage"] = "invalid_detail_probe"
                return record
            }
            await DevelopmentAndroidSiteProvider.shutdownAll()
            phase(site, "detail_probe_warmup", directory: directory)
            record["probe_warmup_completed"] = await bounded(seconds: 65) {
                do { _ = try await SiteApi.shared.homeContent(site: site) }
                catch { record["probe_warmup_error"] = safe(String(describing: error)) }
            }
            phase(site, "detail_probe_observation_window", directory: directory)
            await inspectionHold(plan)
            phase(site, "exact_detail_probe", directory: directory)
            var details: [Vod] = []
            let completed = await bounded(seconds: 65) {
                do {
                    details = try await SiteApi.shared.detailContent(key: site.key, id: probeID, sites: [site]).list
                } catch { record["detail_probe_error"] = safe(String(describing: error)) }
            }
            record["probe_completed"] = completed
            record["detail_items"] = details.count
            record["detail_episode_counts"] = details.map { $0.parseFlags().map { $0.episodes.count } }
            record["status"] = completed && !details.isEmpty ? "detail_probe_success" : "detail_probe_failed"
            record["seconds"] = Int(Date().timeIntervalSince(started))
            return record
        }
        if let probeID = plan.categoryProbeID {
            // Reset preceding search and hover work. Optional home warmup is
            // explicit in the record; this diagnostic never counts as playback.
            await DevelopmentAndroidSiteProvider.shutdownAll()
            record["diagnostic_only"] = true
            if plan.categoryProbeWarmup == true {
                // An optional observation window loads the original business
                // classes before an external, read-only HTTP observer attaches.
                // Keep this distinct from the direct fresh-helper probe.
                record["probe_home_warmup"] = true
                phase(site, "category_probe_warmup", directory: directory)
                record["probe_warmup_completed"] = await bounded(seconds: 65) {
                    do { _ = try await SiteApi.shared.homeContent(site: site) }
                    catch { record["probe_warmup_error"] = safe(String(describing: error)) }
                }
                phase(site, "category_probe_observation_window", directory: directory)
                await inspectionHold(plan)
            }
            phase(site, plan.categoryProbeWarmup == true ? "warmed_category_probe" : "fresh_category_probe", directory: directory)
            var resolution = DevelopmentAndroidFolderAudit.Resolution()
            let complete = await bounded(seconds: 150) {
                resolution = await DevelopmentAndroidFolderAudit.resolve(
                    Vod(vodId: probeID, isFolder: true), allowEmptyRootID: true, isFolder: \.isFolder
                ) { folder in
                    do {
                        let result = try await SiteApi.shared.categoryContent(key: site.key,
                            tid: folder.vodId, page: "1", filter: true, extend: [:], sites: [site])
                        return .init(items: result.list)
                    } catch { return .init(items: [], error: safe(String(describing: error))) }
                }
            }
            record["probe_completed"] = complete
            record["folder_navigation"] = resolution.visits.map {
                ["category_id_sha256": hash(Data($0.id.utf8)), "depth": $0.depth,
                 "items": $0.items, "folders": $0.folders, "error": $0.error ?? ""] as [String: Any]
            }
            record["leaf_id_sha256"] = resolution.leaf.map { hash(Data($0.vodId.utf8)) } ?? ""
            record["failure_stage"] = complete ? (resolution.failure ?? "") : "category_probe_timeout"
            record["status"] = complete && resolution.leaf != nil ? "category_probe_success" : "category_probe_failed"
            return record
        }
        state.selectedTab = .vodHome
        phase(site, "home", directory: directory)
        let homeStart = ProcessInfo.processInfo.systemUptime
        let homeCompleted: Bool
        if useConfigurationHome {
            homeCompleted = true
            record["home_origin"] = "configuration_first_load"
            record["home_ms"] = state.developmentAndroidHomeObservation?.elapsedMS
        } else {
            homeCompleted = await bounded(seconds: 100) { await state.changeSite(site: site) }
            record["home_origin"] = "site_change"
            record["home_ms"] = DevelopmentAndroidSampling.milliseconds(since: homeStart)
        }
        record["home_completed"] = homeCompleted
        record["categories"] = state.categories.map { ["id": $0.typeId, "name": $0.typeName] }
        record["category_inventory"] = state.categories.map { category -> [String: Any] in
            let exclusion = DevelopmentAndroidSampling.categoryExclusion(id: category.typeId, name: category.typeName)
            return ["id": category.typeId, "name": category.typeName,
                "media_category": exclusion == nil, "exclusion": exclusion ?? ""]
        }
        record["home_items"] = state.vods.count
        record["home_error"] = state.vodError.map(safe) ?? ""
        record["home_status"] = DevelopmentAndroidAuditContract.catalogStatus(completed: homeCompleted,
            isCurrentSite: state.activeSite?.key == site.key, error: state.vodError, items: state.vods.count,
            requestFailed: homeRequestFailed(state))
        record["home_observation"] = homeObservation(state)
        if let stopped = await stopForUserAction(state, record: record, directory: directory) { return stopped }
        guard homeCompleted, state.activeSite?.key == site.key else {
            record["failure_stage"] = "home_timeout"
            return record
        }
        // Configuration, account and push entries do not represent video channels.
        if ["点我切源", "MDrive", "push_agent", "cc"].contains(site.key) {
            record["status"] = "utility_entry"
            record["failure_stage"] = "not_a_video_channel"
            return record
        }
        if plan.inventoryOnly == true {
            record["inventory_only"] = true
            record["status"] = record["home_status"]
            // Revisit evidence never overwrites the original cold-start result.
            var revisits = [[String: Any]]()
            for revisit in (plan.homeRevisits ?? []).prefix(3) {
                let complete = await bounded(seconds: 100) {
                    if revisit == .restartHelper { await DevelopmentAndroidSiteProvider.shutdownAll() }
                    await state.loadHomeContent(forceRefresh: revisit != .cached)
                }
                revisits.append(["operation": revisit.rawValue, "observation": homeObservation(state),
                    "items": state.vods.count, "error": state.vodError.map(safe) ?? "",
                    "status": DevelopmentAndroidAuditContract.catalogStatus(completed: complete,
                        isCurrentSite: state.activeSite?.key == site.key, error: state.vodError, items: state.vods.count,
                        requestFailed: homeRequestFailed(state))])
                record["home_revisits"] = revisits
                if let stopped = await stopForUserAction(state, record: record, directory: directory) { return stopped }
                if !complete { break }
            }
            record["home_revisits"] = revisits
            record["seconds"] = Int(Date().timeIntervalSince(started))
            return record
        }
        if let replay = plan.exactPlayback {
            guard replay.isValid, (developmentRegistered || plan.providerExecutionPreference == .macPreferred),
                    plan.only == [site.key],
                  plan.categoryID == nil, plan.searchKeyword == nil, plan.sampleVodID == nil,
                  plan.categoryProbeID == nil, plan.detailProbeID == nil,
                  plan.requestedPlayFlag == nil || plan.requestedPlayFlag == replay.flag else {
                record["failure_stage"] = "invalid_exact_playback_replay"
                return record
            }
            record["sample_origin"] = "exact_item_replay"
            record["catalog_validation"] = false
            record["requested_file_id_sha256"] = replay.fileID.map { hash(Data($0.utf8)) }
            record["requested_episode_url_sha256"] = replay.episodeURLSHA256
            record["requested_episode_identity_sha256"] = replay.episodeIdentitySHA256
        }
        var candidates = plan.exactPlayback.map { [Vod(vodId: $0.vodID)] }
            ?? state.vods.filter { !$0.isFolder || isBrowsableFolder($0) }
        await inspectionHold(plan)
        var categoryResults = [[String: Any]]()
        let contentCategories = state.categories.filter { category in
            if plan.exactPlayback != nil || plan.homeOnly == true || plan.searchKeyword != nil { return false }
            if let selected = plan.categoryID { return category.typeId == selected }
            return DevelopmentAndroidSampling.categoryExclusion(id: category.typeId, name: category.typeName) == nil
        }
        for category in contentCategories.prefix(3) {
            if let stopped = await stopForUserAction(state, record: record, directory: directory) { return stopped }
            phase(site, "category", directory: directory)
            let categoryStart = ProcessInfo.processInfo.systemUptime
            let complete = await bounded(seconds: 60) { await state.selectCategory(category, forceRefresh: true) }
            let status = DevelopmentAndroidAuditContract.categoryStatus(state: state, id: category.typeId, completed: complete)
            categoryResults.append(["id": category.typeId, "name": category.typeName,
                "elapsed_ms": DevelopmentAndroidSampling.milliseconds(since: categoryStart),
                "completed": complete, "items": state.vods.count, "error": state.vodError.map(safe) ?? "",
                "status": status, "request_outcome": state.developmentAndroidCategoryObservation?.outcome ?? "unobserved",
                "original_payload": state.developmentAndroidCategoryObservation?.androidCategoryPayload?.rawValue ?? "unobserved"])
            record["category_attempts"] = categoryResults
            if let stopped = await stopForUserAction(state, record: record, directory: directory) { return stopped }
            guard complete else {
                record["category_attempts"] = categoryResults
                record["failure_stage"] = "category_timeout"
                return record
            }
            if status == "catalog_observed" {
                candidates = state.vods.filter { !$0.isFolder || isBrowsableFolder($0) }
                break
            }
        }
        record["category_attempts"] = categoryResults
        record["category_has_items"] = categoryResults.contains { $0["status"] as? String == "catalog_observed" }
        if let requestedCategory = plan.categoryID {
            record["requested_category"] = requestedCategory
            guard record["category_has_items"] as? Bool == true else {
                record["failure_stage"] = DevelopmentAndroidAuditContract.requestedCategoryFailure(
                    advertised: !contentCategories.isEmpty, status: categoryResults.last?["status"] as? String)
                record["poster_items"] = 0
                record["poster_urls_present"] = 0
                return record
            }
        }
        // Search-only entries must be exercised through a real search, rather
        // than reporting a deliberately empty home as a broken poster wall.
        if plan.exactPlayback == nil && (plan.searchKeyword != nil
            || (plan.categoryID == nil && plan.homeOnly != true && candidates.isEmpty && (["ZPan", "JPan", "YpanSo", "BpanSo", "抠搜", "UC"].contains(site.key)
                || (developmentRegistered && site.api == "csp_SeedhubGuard")))) {
            state.selectedSearchSiteKeys = [site.key]
            state.selectedTab = .search
            phase(site, "search", directory: directory)
            let searchStart = ProcessInfo.processInfo.systemUptime
            let completed = await bounded(seconds: 65) {
                await state.search(keyword: plan.searchKeyword ?? "庆余年",
                                   forceRefresh: true)
            }
            record["search_ms"] = DevelopmentAndroidSampling.milliseconds(since: searchStart)
            record["search_completed"] = completed
            if let stopped = await stopForUserAction(state, record: record, directory: directory) { return stopped }
            guard completed else {
                record["failure_stage"] = "search_timeout"
                return record
            }
            let result = state.searchResults.first { $0.siteKey == site.key }
            candidates = (result?.vods ?? []).filter { !$0.isFolder || isBrowsableFolder($0) }
            if let error = result?.error { record["search_error"] = safe(error) }
            record["search_items"] = candidates.count
        }
        if let stopped = await stopForUserAction(state, record: record, directory: directory) { return stopped }
        record["poster_items"] = candidates.count
        record["folder_items"] = candidates.filter(isBrowsableFolder).count
        phase(site, "posters", directory: directory)
        await inspectionHold(plan)
        record["poster_urls_present"] = candidates.filter { !$0.vodPic.isEmpty }.count
        if let poster = candidates.first(where: { !$0.vodPic.isEmpty }) {
            record["poster_sample"] = await verifyPoster(poster.vodPic, headers: site.header)
        }
        guard !candidates.isEmpty else {
            record["failure_stage"] = "catalog"
            return record
        }
        var attempts = [[String: Any]]()
        let selectedIndices: [Int]
        if let sampleVodID = plan.sampleVodID {
            guard let index = candidates.firstIndex(where: { $0.vodId == sampleVodID }) else {
                record["failure_stage"] = "requested_sample_missing_from_catalog"
                return record
            }
            selectedIndices = [index]
        } else {
            selectedIndices = DevelopmentAndroidSampling.indices(ids: candidates.map(\.vodId),
                seed: plan.samplingSeed, scope: site.key + ":" + (plan.categoryID ?? (plan.homeOnly == true ? "home" : "default")),
                offset: plan.sampleOffset ?? 0, count: plan.sampleCount ?? 2)
        }
        record["selected_sample_count"] = selectedIndices.count
        record["selected_catalog_indices"] = selectedIndices
        record["selected_vod_id_sha256"] = selectedIndices.map { hash(Data(candidates[$0].vodId.utf8)) }
        for index in selectedIndices {
            if let stopped = await stopForUserAction(state, record: record, attempts: attempts, directory: directory) { return stopped }
            let vod = candidates[index]
            var attempt: [String: Any] = ["title": vod.vodName, "vod_id_sha256": hash(Data(vod.vodId.utf8))]
            let posterStart = ProcessInfo.processInfo.systemUptime
            attempt["poster_sample"] = await verifyPoster(vod.vodPic, headers: site.header,
                probeTransport: plan.posterTransportProbe == true)
            attempt["poster_ms"] = DevelopmentAndroidSampling.milliseconds(since: posterStart)
            var resolution = DevelopmentAndroidFolderAudit.Resolution()
            let folderStart = ProcessInfo.processInfo.systemUptime
            let navigationCompleted = await bounded(seconds: 180) {
                resolution = await DevelopmentAndroidFolderAudit.resolve(vod, isFolder: isBrowsableFolder) { folder in
                    guard state.cloudAuthRequest == nil, state.playbackVerificationRequest == nil else {
                        return .init(items: [], error: "user_action_required")
                    }
                    phase(site, "folder", directory: directory)
                    await state.openVodCard(folder)
                    return .init(items: state.vods, error: state.vodError)
                }
            }
            attempt["folder_ms"] = DevelopmentAndroidSampling.milliseconds(since: folderStart)
            attempt["folder_navigation_completed"] = navigationCompleted
            attempt["nested_categories"] = resolution.visits.count
            attempt["folder_navigation"] = resolution.visits.map { visit -> [String: Any] in
                ["category_id_sha256": hash(Data(visit.id.utf8)), "depth": visit.depth,
                 "items": visit.items, "folders": visit.folders, "error": visit.error.map(safe) ?? ""]
            }
            if let stopped = await stopForUserAction(state, record: record, attempts: attempts + [attempt], markLastAttempt: true, directory: directory) { return stopped }
            guard navigationCompleted else {
                attempt["failure_stage"] = "folder_timeout"
                record["attempts"] = attempts + [attempt]
                return record
            }
            guard let leaf = resolution.leaf else {
                attempt["failure_stage"] = resolution.failure ?? "folder_no_leaf"
                attempts.append(attempt)
                progress(record, attempts: attempts, directory: directory)
                continue
            }
            attempt["leaf_vod_id_sha256"] = hash(Data(leaf.vodId.utf8))
            attempt["leaf_depth"] = resolution.leafDepth
            if leaf.vodId != vod.vodId {
                let leafPosterStart = ProcessInfo.processInfo.systemUptime
                attempt["leaf_poster_sample"] = await verifyPoster(leaf.vodPic, headers: site.header)
                attempt["leaf_poster_ms"] = DevelopmentAndroidSampling.milliseconds(since: leafPosterStart)
            }
            phase(site, "detail", directory: directory)
            let detailStart = ProcessInfo.processInfo.systemUptime
            let complete = await bounded(seconds: 65) { await state.openVodCard(leaf) }
            attempt["detail_ms"] = DevelopmentAndroidSampling.milliseconds(since: detailStart)
            attempt["detail_completed"] = complete
            attempt["detail_request_outcome"] = state.detailRequestOutcome.rawValue
            attempt["detail_presented"] = state.isDetailPresented
            attempt["detail_title"] = state.detailVod?.vodName ?? ""
            attempt["flags"] = state.playFlags
            let requestedPlayFlag = plan.exactPlayback?.flag ?? plan.requestedPlayFlag
            attempt["requested_play_flag"] = requestedPlayFlag
            if let stopped = await stopForUserAction(state, record: record, attempts: attempts + [attempt], markLastAttempt: true, directory: directory) { return stopped }
            guard complete else {
                attempt["failure_stage"] = "detail_timeout"
                record["attempts"] = attempts + [attempt]
                return record
            }
            if let failure = DevelopmentAndroidAuditContract.detailRequestFailure(state.detailRequestOutcome) {
                attempt["failure_stage"] = failure
                attempt["status"] = "detail_failed"
                attempt["episodes"] = state.episodes.count
                attempts.append(attempt)
                state.isDetailPresented = false
                progress(record, attempts: attempts, directory: directory)
                continue
            }
            if state.isDetailPresented, let requestedFlag = requestedPlayFlag {
                let selected = selectRequestedPlayFlag(requestedFlag, state: state)
                attempt["requested_play_flag_selected"] = selected
                guard selected else {
                    attempt["failure_stage"] = "requested_play_flag_not_available"
                    attempts.append(attempt)
                    state.isDetailPresented = false
                    progress(record, attempts: attempts, directory: directory)
                    continue
                }
            }
            attempt["episodes"] = state.episodes.count
            if state.isDetailPresented, let detail = state.detailVod {
                let detailPosterStart = ProcessInfo.processInfo.systemUptime
                attempt["detail_poster_sample"] = await verifyPoster(detail.vodPic, headers: site.header)
                attempt["detail_poster_ms"] = DevelopmentAndroidSampling.milliseconds(since: detailPosterStart)
            }
            let episodeIndex: Int
            if let replay = plan.exactPlayback {
                attempt["exact_file_match_count"] = replay.matchingIndices(in: state.episodes).count
                attempt["exact_identity_match_count"] = replay.identityMatchingIndices(in: state.episodes).count
                attempt["episode_contract_kinds"] = replay.episodeKinds(in: state.episodes)
                guard let selected = replay.episodeIndex(in: state.episodes) else {
                    attempt["failure_stage"] = "requested_file_missing_or_ambiguous"
                    attempts.append(attempt)
                    state.isDetailPresented = false
                    progress(record, attempts: attempts, directory: directory)
                    continue
                }
                episodeIndex = selected
                attempt["exact_file_selected"] = true
            } else {
                episodeIndex = max(0, plan.episodeIndex ?? 0)
            }
            if let failure = DevelopmentAndroidAuditContract.detailFailure(presented: state.isDetailPresented,
                hasDetail: state.detailVod != nil, episodes: state.episodes.count, requestedIndex: episodeIndex,
                requestOutcome: state.detailRequestOutcome) {
                attempt["failure_stage"] = failure
                attempt["status"] = "detail_failed"
                attempts.append(attempt)
                state.isDetailPresented = false
                progress(record, attempts: attempts, directory: directory)
                continue
            }
            let episode = state.episodes[episodeIndex]
            let flag = state.selectedPlayFlag
            let requestedVodID = state.detailVod?.vodId ?? leaf.vodId
            let playbackScope = DevelopmentAndroidMagnetAudit.Scope(site: site, flag: flag, vodID: requestedVodID)
            let originalEpisodes = state.episodes
            let needsMagnetExpansion = DevelopmentAndroidMagnetAudit.requiresNativeExpansion(episode, site: site, backend: state.providerExecutionBackends[site.key])
            var playbackEpisode = episode
            var preparationFailure: String?
            await inspectionHold(plan)
            attempt["requested_flag"] = flag
            attempt["episode"] = episode.name
            attempt["original_episode_name_sha256"] = hash(Data(episode.name.utf8))
            attempt["original_episode_url_sha256"] = hash(Data(episode.url.utf8))
            let isMagnet = URLComponents(string: episode.url)?.scheme?.lowercased() == "magnet"
            var savedHistory: History?
            if plan.resumeFromSavedHistory == true {
                savedHistory = DevelopmentAndroidHistoryAudit.matchingHistory(state.historyItems,
                    siteKey: site.key, vodID: requestedVodID, detailRequestID: leaf.vodId,
                    flag: flag, episodeURL: episode.url,
                    sourceFingerprint: state.librarySourceFingerprint(siteKey: site.key))
                guard !isMagnet, !needsMagnetExpansion, let savedHistory else {
                    attempt["failure_stage"] = "saved_history_missing_or_ambiguous"
                    attempt["status"] = "playback_failed"
                    attempts.append(attempt)
                    progress(record, attempts: attempts, directory: directory)
                    break
                }
                attempt["playback_entry"] = "production_saved_history"
                attempt["saved_history_position_ms"] = savedHistory.position
                attempt["saved_history_duration_ms"] = savedHistory.duration
                attempt["saved_history_source_fingerprint"] = savedHistory.sourceFingerprint
            }
            let preparationBudget = isMagnet ? 105 : 75
            let preparationPhase = isMagnet ? "magnet_metadata_and_playback_prepare" : "playback"
            attempt["preparation_kind"] = isMagnet ? "magnet" : "standard"
            attempt["preparation_budget_seconds"] = preparationBudget
            attempt["preparation_phase"] = preparationPhase
            // The production magnet resolver may wait 90 seconds for metadata.
            // AppState exposes no separate metadata-ready status, so retain a
            // combined phase instead of attributing every timeout to metadata.
            phase(site, preparationPhase, directory: directory)
            let playbackStart = ProcessInfo.processInfo.systemUptime
            let prepared = await bounded(seconds: preparationBudget) {
                guard !Task.isCancelled, state.cloudAuthRequest == nil,
                      state.playbackVerificationRequest == nil,
                      playbackScope.matches(site: state.activeSite,
                    flag: state.selectedPlayFlag, vodID: state.detailVod?.vodId) else {
                    preparationFailure = "playback_context_changed"
                    return
                }
                if let savedHistory { await state.playHistory(savedHistory) }
                else { await state.playEpisode(episode, resumePosition: 0, restartFromBeginning: true) }
                guard !Task.isCancelled, state.cloudAuthRequest == nil,
                      state.playbackVerificationRequest == nil else { return }
                if needsMagnetExpansion {
                    guard playbackScope.matches(site: state.activeSite, flag: state.selectedPlayFlag,
                                                vodID: state.detailVod?.vodId) else {
                        preparationFailure = "magnet_context_changed"
                        return
                    }
                    do {
                        let selection = try DevelopmentAndroidMagnetAudit.select(
                            original: episode, before: originalEpisodes, after: state.episodes)
                        playbackEpisode = selection.episode
                        attempt["magnet_identity_sha256"] = hash(Data(selection.magnetIdentity.utf8))
                        attempt["magnet_file_count"] = selection.fileCount
                        attempt["selected_file_index"] = selection.fileIndex
                        attempt["selected_file_name_sha256"] = hash(Data(selection.episode.name.utf8))
                        attempt["selected_file_url_sha256"] = hash(Data(selection.episode.url.utf8))
                        attempt["magnet_selection"] = selection.requiresExplicitSelection
                            ? "audit_file_click" : "single_file_automatic"
                        // A single file was already selected by AppState. Multiple
                        // files require the same second click as the detail UI.
                        if selection.requiresExplicitSelection {
                            phase(site, "magnet_file_playback", directory: directory)
                            await state.playEpisode(selection.episode, resumePosition: 0, restartFromBeginning: true)
                        }
                    } catch let failure as DevelopmentAndroidMagnetAudit.Failure {
                        preparationFailure = failure.rawValue
                        return
                    } catch {
                        preparationFailure = "magnet_selection_invalid"
                        return
                    }
                }
                guard !Task.isCancelled, state.cloudAuthRequest == nil,
                      state.playbackVerificationRequest == nil else { return }
                if let selection = state.pendingPlaybackSelection {
                    guard let candidate = selection.candidates.first(where: {
                        $0.isPlayable && (plan.requestedQuality == nil || $0.name == plan.requestedQuality)
                            && (plan.requestedMagnetFileIndex == nil || ($0.providerKey == "host.torrent"
                                && $0.id.split(separator: ":").dropFirst(2).first.flatMap { Int($0) } == plan.requestedMagnetFileIndex))
                    }) else {
                        preparationFailure = "requested_quality_unavailable"
                        return
                    }
                    attempt["quality_options"] = selection.candidates.map(\.name)
                    attempt["requested_quality"] = candidate.name
                    await state.selectPlaybackCandidate(candidate)
                }
                if let host = state.playerState.currentSpec?.hostMagnet {
                    guard let file = host.selectedFile,
                          host.files.contains(where: { $0.identity == file.identity && $0.url == file.url }),
                          state.playerState.currentSpec?.mediaIdentity == file.identity.mediaIdentity,
                          state.playerState.currentSpec?.metadata["vod.episodeURL"] == episode.url,
                          !isMagnet || MagnetURI.infoHash(in: episode.url) == file.identity.infoHash,
                          plan.requestedMagnetFileIndex == nil || file.identity.fileIndex == plan.requestedMagnetFileIndex else {
                        preparationFailure = "magnet_file_identity_invalid"
                        return
                    }
                    attempt["magnet_identity_sha256"] = hash(Data(file.identity.infoHash.utf8))
                    attempt["magnet_file_count"] = host.files.count
                    attempt["selected_file_index"] = file.identity.fileIndex
                    attempt["selected_file_length"] = file.identity.length
                    attempt["selected_file_name_sha256"] = hash(Data(file.name.utf8))
                    attempt["magnet_selection"] = host.files.count == 1 ? "host_single_file_automatic" : "host_file_selection"
                }
            }
            attempt["player_preparation_ms"] = DevelopmentAndroidSampling.milliseconds(since: playbackStart)
            attempt["play_call_completed"] = prepared
            attempt["native_failure"] = await nativeFailureObservation(for: state.playerState.currentSpec)
            if let stopped = await stopForUserAction(state, record: record, attempts: attempts + [attempt], markLastAttempt: true, directory: directory) { return stopped }
            guard prepared, !state.playbackPreparationTimedOut else {
                timedOut = true
                attempt["status"] = "playback_timeout"
                attempt["timeout_origin"] = prepared ? "playback_operation" : "audit_preparation_deadline"
                attempt["failure_stage"] = "playback_timeout"
                attempt["error"] = (state.playerState.errorMessage ?? state.playbackErrorMessage).map(safe) ?? ""
                record["attempts"] = attempts + [attempt]
                return record
            }
            if let preparationFailure {
                attempt["failure_stage"] = preparationFailure
                attempt["status"] = "playback_failed"
                attempt["error"] = (state.playerState.errorMessage ?? state.playbackErrorMessage).map(safe) ?? ""
                attempts.append(attempt)
                await retire(state)
                progress(record, attempts: attempts, directory: directory)
                continue
            }
            let consumer = UUID()
            state.playerState.setPlaybackInformationVisible(true, consumer: consumer)
            let samplingStart = ProcessInfo.processInfo.systemUptime
            let observationSeconds = Double(min(45, max(10, plan.playbackSeconds ?? 25)))
            let fullObservation = plan.observeFullPlaybackWindow == true
            let waitBudget = fullObservation
                ? max(observationSeconds, min(1200, Double(plan.playbackObservationTimeoutSeconds ?? 80)))
                : observationSeconds
            let deadline = samplingStart + waitBudget
            let requiredOutput = plan.requiredOutput ?? .audioAndVideo
            var samples = [[String: Any]]()
            var progressObservation = DevelopmentAndroidSampling.PlaybackProgress()
            var continuous = DevelopmentAndroidSampling.ContinuousPlaybackWindow(requiredSeconds: observationSeconds)
            var advanced = false
            var samplingIdentityChanged = false
            var landing = savedHistory.map {
                DevelopmentAndroidSampling.PlaybackTargetLanding(targetSeconds: Double($0.position) / 1000)
            }
            repeat {
                let now = ProcessInfo.processInfo.systemUptime
                let player = state.playerState
                let diagnostics = player.playbackDiagnostics
                let videoReady = !(diagnostics?.video.codec ?? "").isEmpty
                    && (diagnostics?.video.width ?? 0) > 0 && (diagnostics?.video.height ?? 0) > 0
                let audioReady = !(diagnostics?.audio.codec ?? "").isEmpty
                    && !(diagnostics?.audio.outputDriver ?? "").isEmpty
                    && (diagnostics?.audio.outputSampleRate ?? 0) > 0
                    && (diagnostics?.audio.outputChannelCount ?? 0) > 0
                let decoded = requiredOutput.accepts(audioDecoded: audioReady, videoDecoded: videoReady,
                    separateAudio: !(player.currentSpec?.externalAudioURL ?? "").isEmpty)
                let identityMatches = player.currentSpec?.siteKey == site.key && player.currentSpec?.flag == flag
                    && player.currentSpec?.metadata["vod.id"] == requestedVodID
                    && player.currentSpec?.metadata["vod.episodeURL"] == playbackEpisode.url
                samples.append(["position": player.position.isFinite ? player.position : 0,
                    "monotonic_seconds": now, "playing": player.isPlaying, "buffering": player.isBuffering,
                    "loading": player.isMediaLoading, "seeking": player.isSeeking, "speed": player.speed,
                    "decoder_ready": decoded, "identity_matches": identityMatches,
                    "duration": player.duration.isFinite ? player.duration : 0])
                if player.currentSpec != nil && !identityMatches { samplingIdentityChanged = true; break }
                if player.isPlaying, !player.isMediaLoading, attempt["first_ready_ms"] == nil {
                    attempt["first_ready_ms"] = DevelopmentAndroidSampling.milliseconds(since: playbackStart)
                }
                if landing != nil {
                    _ = landing?.observe(position: player.position, settled: decoded && identityMatches
                        && player.isPlaying && !player.isMediaLoading && !player.isBuffering
                        && !player.isSeeking && player.speed == 1)
                    if landing?.failed == true { break }
                }
                let targetReached = landing?.reached ?? true
                if fullObservation {
                    advanced = continuous.observe(time: now, position: player.position, playing: player.isPlaying,
                        loading: player.isMediaLoading, buffering: player.isBuffering, seeking: player.isSeeking,
                        speed: Double(player.speed), decoded: decoded, identityMatches: identityMatches && targetReached)
                    if advanced { break }
                } else if targetReached && progressObservation.observe(position: player.position, playing: player.isPlaying,
                    loading: player.isMediaLoading, buffering: player.isBuffering) {
                    advanced = true
                    break
                }
                if state.cloudAuthRequest != nil || state.playbackVerificationRequest != nil
                    || state.playerState.errorMessage != nil || state.isPlaybackErrorPresented { break }
                try? await Task.sleep(for: .seconds(1))
            } while ProcessInfo.processInfo.systemUptime < deadline && !Task.isCancelled
            state.playerState.setPlaybackInformationVisible(false, consumer: consumer)
            let healthy = !Task.isCancelled && state.cloudAuthRequest == nil
                && state.playbackVerificationRequest == nil && state.playerState.errorMessage == nil
                && !state.isPlaybackErrorPresented && !samplingIdentityChanged && landing?.failed != true
            let observationComplete = healthy && (fullObservation ? continuous.complete
                : ProcessInfo.processInfo.systemUptime >= deadline)
            let observationExpired = fullObservation && healthy && !continuous.complete
                && ProcessInfo.processInfo.systemUptime >= deadline
            if samplingIdentityChanged { attempt["failure_stage"] = "playback_context_changed" }
            if observationExpired {
                timedOut = true
                attempt["failure_stage"] = "playback_observation_timeout"
                attempt["timeout_origin"] = "continuous_observation_deadline"
            }
            if let landing {
                attempt["target_seconds"] = landing.targetSeconds
                attempt["target_tolerance_seconds"] = landing.toleranceSeconds
                attempt["target_reached"] = landing.reached
                attempt["target_first_settled_position"] = landing.firstSettledPosition
                attempt["target_landing_method"] = "first_settled_decoded_position"
                if landing.failed { attempt["failure_stage"] = "playback_target_not_restored" }
            }
            attempt["native_failure"] = await nativeFailureObservation(for: state.playerState.currentSpec)
            attempt["samples"] = samples
            attempt["playback_sampling_ms"] = DevelopmentAndroidSampling.milliseconds(since: samplingStart)
            attempt["playback_sampling_budget_ms"] = observationSeconds * 1000
            attempt["playback_observation_wait_budget_ms"] = waitBudget * 1000
            attempt["full_observation_required"] = fullObservation
            attempt["observation_window_complete"] = observationComplete
            attempt["timeline_advanced"] = advanced
            if fullObservation {
                attempt["continuous_playback_seconds"] = continuous.elapsedSeconds
                attempt["continuous_media_advanced_seconds"] = continuous.advancedSeconds
                attempt["continuous_sample_count"] = continuous.sampleCount
                attempt["continuous_first_position"] = continuous.firstPosition
                attempt["continuous_last_position"] = continuous.lastPosition
            }
            attempt["player_presented"] = state.isPlayerPresented
            attempt["actual_flag"] = state.selectedPlayFlag
            attempt["same_flag"] = state.selectedPlayFlag == flag
            attempt["actual_site"] = state.activeSite?.key ?? ""
            attempt["same_site"] = state.activeSite?.key == site.key
            attempt["authentication_required"] = state.cloudAuthRequest != nil
            attempt["verification_required"] = state.playbackVerificationRequest != nil
            attempt["error"] = (state.playerState.errorMessage ?? state.playbackErrorMessage).map(safe) ?? ""
            if let stopped = await stopForUserAction(state, record: record, attempts: attempts + [attempt], markLastAttempt: true, directory: directory) { return stopped }
            var videoDecoded = false
            var audioDecoded = false
            if let diagnostics = state.playerState.playbackDiagnostics {
                // Decoder facts contain no media URLs or authentication headers.
                attempt["decoder"] = ["codec": diagnostics.video.codec ?? "",
                    "width": diagnostics.video.width ?? 0, "height": diagnostics.video.height ?? 0]
                attempt["audio_output"] = ["codec": diagnostics.audio.codec ?? "",
                    "driver": diagnostics.audio.outputDriver ?? "",
                    "sample_rate": diagnostics.audio.outputSampleRate ?? 0,
                    "channels": diagnostics.audio.outputChannelCount ?? 0]
                videoDecoded = !(diagnostics.video.codec ?? "").isEmpty
                    && (diagnostics.video.width ?? 0) > 0 && (diagnostics.video.height ?? 0) > 0
                audioDecoded = !(diagnostics.audio.codec ?? "").isEmpty
                    && !(diagnostics.audio.outputDriver ?? "").isEmpty
                    && (diagnostics.audio.outputSampleRate ?? 0) > 0
                    && (diagnostics.audio.outputChannelCount ?? 0) > 0
            }
            if let spec = state.playerState.currentSpec {
                attempt["subtitle_sources"] = spec.subs.map { sub -> [String: Any] in
                    let url = URLComponents(string: sub.url)
                    return ["url_sha256": hash(Data(sub.url.utf8)), "scheme": url?.scheme ?? "",
                        "loopback": ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url?.host ?? ""),
                        "port": url?.port ?? 0, "proxy_path": url?.path == "/proxy",
                        "query_keys": url?.queryItems?.map(\.name) ?? [], "format": sub.format]
                }
                attempt["subtitle_tracks_loaded"] = state.playerState.subtitleTracks.count
                attempt["subtitle_selected"] = state.playerState.selectedSubtitleTrackID != nil
                attempt["subtitle_status"] = state.playerState.subtitleStatus.map(safe) ?? ""
                attempt["media_url_sha256"] = hash(Data(spec.url.utf8))
                attempt["spec_site"] = spec.siteKey
                attempt["spec_flag"] = spec.flag
                attempt["spec_identity_matches"] = spec.siteKey == site.key && spec.flag == flag
                    && spec.metadata["vod.id"] == requestedVodID && spec.metadata["vod.episodeURL"] == playbackEpisode.url
            }
            let separateAudio = !(state.playerState.currentSpec?.externalAudioURL ?? "").isEmpty
            attempt["required_output"] = requiredOutput.rawValue
            attempt["required_output_basis"] = plan.requiredOutput == nil ? "strict_default" : "explicit_plan"
            attempt["decoder_confirmed"] = videoDecoded || audioDecoded
            attempt["separate_audio_confirmed"] = !separateAudio || (videoDecoded && audioDecoded)
            let passed = prepared && advanced && (!fullObservation || observationComplete) && requiredOutput.accepts(audioDecoded: audioDecoded,
                videoDecoded: videoDecoded, separateAudio: separateAudio)
                && state.selectedPlayFlag == flag && state.activeSite?.key == site.key
                && playbackScope.matches(site: state.activeSite, flag: state.selectedPlayFlag,
                                         vodID: state.detailVod?.vodId)
                && (attempt["spec_identity_matches"] as? Bool == true)
            attempt["status"] = observationExpired ? "playback_timeout" : (passed ? "playback_progress" : "playback_failed")
            attempt["playback_observation_ms"] = DevelopmentAndroidSampling.milliseconds(since: playbackStart)
            if passed, let contract = plan.attachmentContract {
                let checks = await DevelopmentAndroidAttachmentAudit.run(contract, state: state)
                attempt["attachment_contract"] = checks
                attempt["attachment_contract_passed"] = !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true }
                attempt["attachment_contract_applicable"] = checks.first?["applicable"] as? Bool ?? true
            }
            if passed, let contract = plan.playbackContract {
                phase(site, "playback_contract", directory: directory)
                let controls = await DevelopmentAndroidPlaybackContractAudit.run(contract, state: state, episode: playbackEpisode,
                    fullObservationSeconds: fullObservation ? observationSeconds : nil,
                    observationTimeoutSeconds: waitBudget, requiredOutput: requiredOutput)
                attempt["playback_contract"] = controls
                attempt["playback_contract_passed"] = !controls.isEmpty && controls.allSatisfy { $0["passed"] as? Bool == true }
                if let failure = controls.compactMap({ $0["failure_stage"] as? String }).first {
                    attempt["failure_stage"] = failure
                    if failure.hasSuffix("_timeout") {
                        timedOut = true
                        attempt["status"] = "playback_timeout"
                    } else if failure == "playback_context_changed" { attempt["status"] = "playback_failed" }
                }
            }
            if let stopped = await stopForUserAction(state, record: record, attempts: attempts + [attempt], markLastAttempt: true, directory: directory) { return stopped }
            attempts.append(attempt)
            progress(record, attempts: attempts, directory: directory)
            if timedOut || samplingIdentityChanged || attempt["failure_stage"] as? String == "playback_context_changed" {
                await retire(state)
                break
            }
            await inspectionHold(plan)
            if let stopped = await stopForUserAction(state, record: record, attempts: attempts, markLastAttempt: true, directory: directory) { return stopped }
            await retire(state)
            if passed, plan.allSelectedSamples != true { break }
        }
        record["attempts"] = attempts
        record["status"] = attempts.contains { ($0["status"] as? String) == "playback_progress" }
            ? "playback_progress" : "failed"
        record["all_selected_samples_completed"] = attempts.count == selectedIndices.count
        record["all_samples_played"] = !attempts.isEmpty && attempts.count == selectedIndices.count
            && attempts.allSatisfy { ($0["status"] as? String) == "playback_progress" }
        record["all_sample_posters_present"] = !attempts.isEmpty && attempts.allSatisfy {
            ($0["poster_sample"] as? [String: Any])?["status"] as? String == "ui_image_present"
                && (($0["leaf_poster_sample"] as? [String: Any])?["status"] as? String ?? "ui_image_present") == "ui_image_present"
                && (($0["detail_poster_sample"] as? [String: Any])?["status"] as? String ?? "missing_detail_poster") == "ui_image_present"
        }
        record["seconds"] = Int(Date().timeIntervalSince(started))
        return record
    }

    static func nativeFailureObservation(for spec: PlaySpec?, engine: MPVPlayerEngine = .vod) async -> [String: Any] {
        guard let spec, var failure = engine.playbackFailure(for: spec) else {
            return ["observed": false]
        }
        // mpv may queue its HTTP log after END_FILE. Give the existing native
        // event queue a bounded window; this never probes or reloads the media.
        let started = ProcessInfo.processInfo.systemUptime
        while failure.httpStatus == nil, ProcessInfo.processInfo.systemUptime - started < 0.25,
              !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
            guard let current = engine.playbackFailure(for: spec) else { return ["observed": false] }
            failure = current
        }
        var record: [String: Any] = [
            "native_log_settle_ms": DevelopmentAndroidSampling.milliseconds(since: started),
            "observed": true, "source": "mpv_current_media_load",
            "native_error": failure.nativeError.map { $0 as Any } ?? NSNull(),
            "http_status": failure.httpStatus.map { $0 as Any } ?? NSNull(),
            "http_status_basis": failure.httpStatus == nil ? "unobserved" : "mpv_http_error_log",
            "playback_started": failure.playbackStarted, "message": safe(failure.message),
            "media_url_sha256": hash(Data(spec.url.utf8)),
            "site_sha256": hash(Data(spec.siteKey.utf8)), "flag_sha256": hash(Data(spec.flag.utf8)),
            "vod_id_sha256": hash(Data((spec.metadata["vod.id"] ?? "").utf8)),
            "episode_url_sha256": hash(Data((spec.metadata["vod.episodeURL"] ?? "").utf8)),
            "playback_generation": spec.metadata["playback.sessionGeneration"] ?? "",
        ]
        if let headers = try? JSONSerialization.data(withJSONObject: spec.headers, options: [.sortedKeys]) {
            record["submitted_headers_sha256"] = hash(headers)
        }
        return record
    }

    private static func homeObservation(_ state: AppState) -> [String: Any] {
        guard let observation = state.developmentAndroidHomeObservation,
              let data = try? JSONEncoder().encode(observation),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }

    private static func homeRequestFailed(_ state: AppState) -> Bool {
        ["error", "error_retained_content", "unsupported"].contains(state.developmentAndroidHomeObservation?.outcome ?? "")
    }

    private static func verifyPoster(_ value: String, headers: [String: String], probeTransport: Bool = false) async -> [String: Any] {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return ["status": "not_http"]
        }
        // Use the window's image loader, including its headers, cache and
        // fallback. An independent URLSession request does not verify that UI.
        let loader = ImageLoader(from: value, headers: headers, maxPixelSize: 1200)
        defer { loader.cancel() }
        loader.load(from: value, headers: headers, timeout: 15, maxPixelSize: 1200)
        let deadline = Date().addingTimeInterval(20)
        while loader.isLoading, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard let image = loader.image else {
            var result: [String: Any] = ["status": loader.isLoading ? "ui_timeout" : "ui_no_image",
                                        "method": "WebImage.ImageLoader"]
            #if DEBUG
            if let failure = loader.diagnosticFailure {
                result["error_domain"] = failure.domain
                result["error_code"] = failure.code
            }
            if probeTransport, let source = EmbeddedImageSource.parse(value), source.url.host == "img.lzipic.com" {
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let request = ImageLoader.makeRequest(url: source.url, headers: headers,
                        embeddedHeaders: source.headers, timeout: 5)
                    let response = try await SourceResourceTransport.diagnoseCataloguePoster(source.url,
                        headers: request.allHTTPHeaderFields ?? [:])
                    let decoded = NSImage(data: response.data)
                    result["transport_probe"] = ["status": response.statusCode, "bytes": response.data.count,
                        "same_resource": response.finalURL == source.url,
                        "image_decoded": decoded != nil, "elapsed_ms": DevelopmentAndroidSampling.milliseconds(since: started)]
                } catch {
                    let failure = error as NSError
                    result["transport_probe"] = ["error_domain": failure.domain, "error_code": failure.code,
                        "elapsed_ms": DevelopmentAndroidSampling.milliseconds(since: started)]
                }
            }
            #endif
            return result
        }
        return ["status": "ui_image_present", "method": "WebImage.ImageLoader",
            "width": image.size.width, "height": image.size.height,
            "may_use_existing_cache_or_fallback": true]
    }

    /// Capture the interaction before retirement clears authorization state.
    /// A stop is returned through every loop, including source and warm replays.
    private static func stopForUserAction(_ state: AppState, record: [String: Any],
        attempts: [[String: Any]]? = nil, markLastAttempt: Bool = false, directory: URL) async -> [String: Any]? {
        let authentication = state.cloudAuthRequest != nil
        let verification = state.playbackVerificationRequest != nil
        guard authentication || verification else { return nil }
        let stage = authentication ? "authentication_required" : "verification_required"
        var result = record
        result["status"] = "stopped_user_action"
        result["failure_stage"] = stage
        result["authentication_required"] = authentication
        result["verification_required"] = verification
        result["all_samples_played"] = false
        result["all_selected_samples_completed"] = false
        var captured = attempts ?? (record["attempts"] as? [[String: Any]] ?? [])
        if markLastAttempt, !captured.isEmpty {
            let last = captured.count - 1
            captured[last]["status"] = "stopped_user_action"
            captured[last]["failure_stage"] = stage
            captured[last]["authentication_required"] = authentication
            captured[last]["verification_required"] = verification
        }
        result["attempts"] = captured
        progress(result, attempts: captured, directory: directory)
        await retire(state)
        return result
    }

    private static func retire(_ state: AppState) async {
        await state.cancelLoading()
        state.cancelCloudAuthorization()
        await MPVPlayerEngine.vod.stopAndWaitForRetirement()
        state.isPlayerPresented = false
        state.isDetailPresented = false
        state.isPlaybackErrorPresented = false
        state.playbackErrorMessage = nil
        state.playerState.errorMessage = nil
    }

    private static func bounded(seconds: Int, operation: @escaping @MainActor () async -> Void) async -> Bool {
        var completed = false
        let work = Task { @MainActor in await operation(); completed = true }
        let deadline = Date().addingTimeInterval(Double(seconds))
        while !completed, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if !completed { timedOut = true; work.cancel() }
        return completed
    }

    private static func write(_ value: [String: Any], directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("app-audit.json"), options: .atomic)
    }

    private static func progress(_ record: [String: Any], attempts: [[String: Any]], directory: URL) {
        var value = record
        value["attempts"] = attempts
        value["updated"] = Date().ISO8601Format()
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("sample-progress.json"), options: .atomic)
        }
    }

    private static func retirement(_ plan: Plan, status: String, elapsed: Double) {
        let value: [String: Any] = ["status": status, "elapsed_ms": elapsed]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: plan.output, isDirectory: true)
                .appendingPathComponent("retirement.json"), options: .atomic)
        }
    }

    private static func phase(_ site: Site, _ phase: String, directory: URL) {
        let value = ["site": site.key, "phase": phase, "at": Date().ISO8601Format()]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("phase.json"), options: .atomic)
        }
        print("[ANDROID_APP_AUDIT] site=\(site.key) phase=\(phase)")
    }

    private static func inspectionHold(_ plan: Plan) async {
        let seconds = min(60, max(0, plan.inspectionHoldSeconds ?? 0))
        if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func safe(_ value: String) -> String {
        value.replacingOccurrences(of: "https?://[^\\s\\\"<>]+", with: "<redacted-url>", options: .regularExpression)
    }

    private enum AuditError: Error { case failed(String) }
}

/// Proves that the UI expanded exactly the selected magnet before an audit
/// clicks a file. This never manufactures an episode or resolves a magnet.
enum DevelopmentAndroidMagnetAudit {
    static func requiresNativeExpansion(_ episode: Episode, site: Site, backend: ProviderExecutionBackend?) -> Bool {
        backend != .androidOriginal && VodPlaybackAvailabilityPolicy.needsMagnetExpansion(episode, site: site)
    }

    struct Scope {
        let site: Site
        let flag: String
        let vodID: String

        func matches(site current: Site?, flag: String, vodID: String?) -> Bool {
            current?.key == site.key && current?.api == site.api && current?.type == site.type
                && flag == self.flag && vodID == self.vodID
        }
    }

    struct Selection {
        let episode: Episode
        let fileIndex: Int
        let fileCount: Int
        let magnetIdentity: String
        var requiresExplicitSelection: Bool { fileCount > 1 }
    }

    enum Failure: String, Error {
        case originalInvalid = "magnet_original_invalid"
        case originalAmbiguous = "magnet_original_ambiguous"
        case notExpanded = "magnet_not_expanded"
        case surroundingEpisodesChanged = "magnet_surrounding_episodes_changed"
        case fileIdentityInvalid = "magnet_file_identity_invalid"
        case duplicateFileIndex = "magnet_duplicate_file_index"
    }

    static func select(original: Episode, before: [Episode], after: [Episode]) throws -> Selection {
        guard let base = magnetIdentity(original.url, requiringFile: false) else { throw Failure.originalInvalid }
        let positions = before.indices.filter { before[$0].url == original.url }
        guard positions.count == 1, let position = positions.first,
              before[position].name == original.name else { throw Failure.originalAmbiguous }
        let fileCount = after.count - before.count + 1
        guard fileCount > 0 else { throw Failure.notExpanded }
        let end = position + fileCount
        guard sameEpisodes(before.prefix(position), after.prefix(position)),
              sameEpisodes(before.suffix(from: position + 1), after.suffix(from: end)) else {
            throw Failure.surroundingEpisodesChanged
        }
        let files = after[position..<end]
        var indices = Set<Int>()
        var first: (Episode, Int)?
        for file in files {
            guard !file.name.isEmpty, let identity = magnetIdentity(file.url, requiringFile: true),
                  identity.base == base.base, let index = identity.fileIndex else {
                throw Failure.fileIdentityInvalid
            }
            guard indices.insert(index).inserted else { throw Failure.duplicateFileIndex }
            if first == nil { first = (file, index) }
        }
        guard let first else { throw Failure.notExpanded }
        return Selection(episode: first.0, fileIndex: first.1, fileCount: fileCount, magnetIdentity: base.base)
    }

    private static func sameEpisodes(_ lhs: ArraySlice<Episode>, _ rhs: ArraySlice<Episode>) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.name == $1.name && $0.url == $1.url }
    }

    private static func magnetIdentity(_ value: String, requiringFile: Bool) -> (base: String, fileIndex: Int?)? {
        guard var components = URLComponents(string: value), components.scheme?.lowercased() == "magnet",
              components.host == nil, components.user == nil, components.password == nil,
              components.port == nil, components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems,
              items.contains(where: { $0.name.lowercased() == "xt" && !($0.value ?? "").isEmpty }) else { return nil }
        let fileItems = items.filter { $0.name == "netvplayer_file" }
        var fileIndex: Int?
        if requiringFile {
            guard fileItems.count == 1, let raw = fileItems[0].value,
                  let index = Int(raw), index >= 0, String(index) == raw else { return nil }
            fileIndex = index
        } else if !fileItems.isEmpty { return nil }
        components.scheme = "magnet"
        // MagnetPlaybackEpisodes uses this same URLComponents round trip.
        // Compare every remaining query item, including trackers and their order.
        components.queryItems = items.filter { $0.name != "netvplayer_file" }
        guard let base = components.string else { return nil }
        return (base, fileIndex)
    }
}
