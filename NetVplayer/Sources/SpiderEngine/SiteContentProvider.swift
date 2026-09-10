// SpiderEngine/SiteContentProvider.swift
// Native replacement contract for Android csp_ crawler sources.

import Foundation
import Models

public protocol SiteContentProvider: Sendable {
    func homeContent(site: Site) async throws -> Result
    func homeVideoContent(site: Site) async throws -> Result?
    func categoryContent(site: Site, tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> Result
    func detailContent(site: Site, id: String) async throws -> Result
    func playerContent(site: Site, flag: String, id: String) async throws -> Result
    func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result
}

public extension SiteContentProvider {
    func homeVideoContent(site: Site) async throws -> Result? {
        nil
    }
}
