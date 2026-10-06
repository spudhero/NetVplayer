// Models/VodClass.swift
// 视频分类模型，对应 FongMi: bean/Class.java

import Foundation

/// 视频分类
public struct VodClass: Codable, Identifiable, Sendable, Equatable {
    public var typeId: String
    public var typeName: String
    public var typeFlag: String
    public var filters: [Filter]

    public var id: String { typeId }

    public init(typeId: String = "", typeName: String = "", typeFlag: String = "", filters: [Filter] = []) {
        self.typeId = typeId
        self.typeName = typeName
        self.typeFlag = typeFlag
        self.filters = filters
    }

    enum CodingKeys: String, CodingKey {
        case typeId = "type_id"
        case typeName = "type_name"
        case typeFlag = "type_flag"
        case filters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if let typeIdVal = try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .typeId) {
            self.typeId = typeIdVal.stringValue
        } else {
            self.typeId = ""
        }
        
        self.typeName = try container.decodeIfPresent(String.self, forKey: .typeName) ?? ""
        self.typeFlag = try container.decodeIfPresent(String.self, forKey: .typeFlag) ?? ""
        self.filters = try container.decodeIfPresent([Filter].self, forKey: .filters) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeId, forKey: .typeId)
        try container.encode(typeName, forKey: .typeName)
        try container.encode(typeFlag, forKey: .typeFlag)
        try container.encode(filters, forKey: .filters)
    }
}
