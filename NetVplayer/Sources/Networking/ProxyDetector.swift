// Networking/ProxyDetector.swift
// 本地代理探测器

import Foundation
import Network

/// 本地网络代理探测器
public final class ProxyDetector: @unchecked Sendable {
    public static let shared = ProxyDetector()
    
    private let lock = NSLock()
    private var _detectedPort: Int? = nil
    
    /// 代理配置提供器，由高层模块（如 AppState）注入，以实现模块解耦
    /// 返回值：mode (0=自动探测, 1=直连模式, 2=自定义代理), customPort (自定义端口)
    public var proxySettingsProvider: (@Sendable () -> (mode: Int, customPort: Int))? = nil
    
    /// 缓存的探测到的可用代理端口
    public var detectedPort: Int? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _detectedPort
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _detectedPort = newValue
        }
    }
    
    private init() {}
    
    /// 清除当前的探测缓存，强制在下次调用时重新探测
    public func clearCache() {
        detectedPort = nil
    }
    
    /// 探测可用的代理端口
    /// - Returns: 可用的代理端口，若无可用代理或设置为直连则返回 nil
    @discardableResult
    public func detectActiveProxy() async -> Int? {
        let (mode, customPort) = proxySettingsProvider?() ?? (0, 7897)
        
        if mode == 1 { // 直连模式
            return nil
        } else if mode == 2 { // 自定义代理模式
            return customPort
        }
        
        // 自动探测模式：
        // 缓存只是一种优化；代理可能在应用运行期间被关闭，因此每次使用前都要复核。
        if let cached = detectedPort {
            if await testProxyPort(cached) {
                return cached
            }
            detectedPort = nil
        }
        
        let ports = [7897, 7890]
        
        // 并发探测可用端口
        let foundPort = await withTaskGroup(of: (Int, Bool).self, returning: Int?.self) { group in
            for port in ports {
                group.addTask {
                    let isOk = await self.testProxyPort(port)
                    return (port, isOk)
                }
            }
            
            for await (port, isOk) in group {
                if isOk {
                    return port
                }
            }
            return nil
        }
        
        self.detectedPort = foundPort
        return foundPort
    }
    
    private final class ConnectionState: @unchecked Sendable {
        private let lock = NSLock()
        private var hasResponded = false
        var connection: NWConnection? = nil
        var continuation: CheckedContinuation<Bool, Never>? = nil
        
        func resolve(with result: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !hasResponded else { return }
            hasResponded = true
            connection?.cancel()
            continuation?.resume(returning: result)
        }
    }

    /// 测试特定的本地代理端口是否可用（检测对应端口是否处于 LISTEN 监听状态）
    private func testProxyPort(_ port: Int) async -> Bool {
        return await withCheckedContinuation { continuation in
            let state = ConnectionState()
            state.continuation = continuation
            
            let host = NWEndpoint.Host("127.0.0.1")
            let endpointPort = NWEndpoint.Port(rawValue: UInt16(port))!
            let connection = NWConnection(host: host, port: endpointPort, using: .tcp)
            state.connection = connection
            
            // 设置超时打断：异步延时 0.5 秒后尝试取消
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                state.resolve(with: false)
            }
            
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    state.resolve(with: true)
                case .failed, .cancelled:
                    state.resolve(with: false)
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
        }
    }
}
