import Foundation
import Models
import Testing

@Suite("Source category filter defaults")
struct CategoryFilterSelectionTests {
    @Test func sourceInitSurvivesDecodingAndRoundTrip() throws {
        let data = Data(#"{"key":"5","name":"字母","init":"B","value":[{"n":"A","v":"A"},{"n":"B","v":"B"}]}"#.utf8)
        let filter = try JSONDecoder().decode(Filter.self, from: data)
        #expect(CategoryFilterSelectionPolicy.normalized(filters: [filter], existing: [:]) == ["5": "B"])
        let restored = try JSONDecoder().decode(Filter.self, from: JSONEncoder().encode(filter))
        #expect(restored == filter)
        #expect(CategoryFilterSelectionPolicy.normalized(filters: [restored], existing: ["5": "A"]) == ["5": "A"])
        #expect(CategoryFilterSelectionPolicy.normalized(filters: [restored], existing: ["5": ""]) == ["5": ""])
    }

    @Test func optionalOptionsDoNotInventFirstDefault() throws {
        for initValue in ["", #", "init":null"#, #", "init":"invalid""#] {
            let data = Data((#"{"key":"5","value":[{"n":"A","v":"A"}]"# + initValue + "}").utf8)
            let filter = try JSONDecoder().decode(Filter.self, from: data)
            #expect(CategoryFilterSelectionPolicy.normalized(filters: [filter], existing: [:]).isEmpty)
            #expect(CategoryFilterSelectionPolicy.normalized(filters: [filter], existing: ["5": "removed"]).isEmpty)
        }
    }

    @Test func blankAndRequiredDefaultsKeepTheirOwnContracts() {
        let values = [FilterValue(name: "A", value: "A"), FilterValue(name: "全部", value: "")]
        let optional = Filter(key: "5", values: values)
        #expect(CategoryFilterSelectionPolicy.normalized(filters: [optional], existing: [:]) == ["5": ""])
        let required = Filter(key: "5", values: [values[0]], isRequired: true)
        #expect(CategoryFilterSelectionPolicy.normalized(filters: [required], existing: ["5": ""]) == ["5": "A"])
    }
}
