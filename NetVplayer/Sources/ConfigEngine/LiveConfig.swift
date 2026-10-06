// ConfigEngine/LiveConfig.swift
// 直播配置管理器

import Foundation
import Models
import Storage

/// 直播配置管理器
public final class LiveConfig: @unchecked Sendable {

    public static let shared = LiveConfig()

    private let hygieneStore: SourceHygieneStore?

    public private(set) var lives: [Live] = []
    public private(set) var currentLive: Live?
    public private(set) var hygieneDecisions: [SourceHygieneDecision] = []

    public init(hygieneStore: SourceHygieneStore? = SourceHygieneStore.shared) {
        self.hygieneStore = hygieneStore
    }

    /// 从配置 JSON 解析直播源
    public func parse(livesArray: [[String: Any]], hygieneStore overrideHygieneStore: SourceHygieneStore? = nil) {
        let data = try? JSONSerialization.data(withJSONObject: livesArray)
        let decoded = data.flatMap { try? JSONDecoder().decode([Live].self, from: $0) } ?? []
        let rules = (overrideHygieneStore ?? hygieneStore)?.loadRules() ?? []
        if rules.isEmpty {
            self.hygieneDecisions = []
            self.lives = decoded
        } else {
            let filtered = SourceHygienePolicy.filterLives(decoded, rules: rules)
            self.hygieneDecisions = filtered.decisions
            self.lives = filtered.items
        }
        if let boot = lives.first(where: { $0.boot }) ?? lives.first {
            currentLive = boot
        } else {
            currentLive = nil
        }
    }

    /// 设置当前直播源
    public func setCurrent(_ live: Live) {
        currentLive = live
    }

    /// 清理
    public func clear() {
        lives = []
        currentLive = nil
        hygieneDecisions = []
    }
}
