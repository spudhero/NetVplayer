import Testing
@testable import NetVplayerApp

struct VodDescriptionPresentationTests {
    @Test
    func prefersExpandedDescriptionAndRemovesDisclosureControls() {
        let raw = "摘要。 ; ; ; ; [展开全部]　完整简介第一句。 完整简介第二句。[收起部分]"

        #expect(VodDescriptionPresentation.text(from: raw) == "完整简介第一句。 完整简介第二句。")
    }

    @Test
    func removesStandaloneCollapseMarkerAndSeparatorFill() {
        let raw = "第一段； ； ; 第二段【收起部分】"

        #expect(VodDescriptionPresentation.text(from: raw) == "第一段 第二段")
    }

    @Test
    func preservesOrdinarySemicolonsAndParagraphs() {
        let raw = "第一季；第二季\n\n第三季"

        #expect(VodDescriptionPresentation.text(from: raw) == raw)
    }

    @Test
    func trimsEmptyAndFullWidthWhitespace() {
        #expect(VodDescriptionPresentation.text(from: "　\u{00A0}\n ") == "")
    }
}
