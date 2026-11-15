import Foundation

// Shared by public and internal tests that mutate the saved-file test store.
actor AsyncTestLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

let sharedSavedFileStoreTestLock = AsyncTestLock()
let sharedHTTPRouteTestLock = AsyncTestLock()

// Proxy-setting tests share exclusion with internal URLProtocol tests, without
// depending on private response fixtures or resetting unrelated drive state.
func withHTTPRouteTestIsolation<T>(_ operation: () async throws -> T) async throws -> T {
    await sharedHTTPRouteTestLock.acquire()
    do {
        let result = try await operation()
        await sharedHTTPRouteTestLock.release()
        return result
    } catch {
        await sharedHTTPRouteTestLock.release()
        throw error
    }
}
