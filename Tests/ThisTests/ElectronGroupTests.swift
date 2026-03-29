import Testing
@testable import ThisCore

@Suite("Electron App Group Drilling")
struct ElectronGroupTests {

    @Test func findsBestChildInSingleLevelGroup() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXButton", title: "Save")
        ])
        let result = findBestChild(in: root)
        #expect(result?.role == "AXButton")
        #expect(result?.title == "Save")
    }

    @Test func drillsTwoLevelsDeep() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [
                MockElement(role: "AXTextField", value: "hello")
            ])
        ])
        let result = findBestChild(in: root)
        #expect(result?.role == "AXTextField")
    }

    @Test func drillsThreeLevelsDeep() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [
                MockElement(role: "AXGroup", children: [
                    MockElement(role: "AXButton", title: "OK")
                ])
            ])
        ])
        let result = findBestChild(in: root)
        #expect(result?.role == "AXButton")
    }

    @Test func stopsAtMaxDepth() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [
                MockElement(role: "AXGroup", children: [
                    MockElement(role: "AXGroup", children: [
                        MockElement(role: "AXButton", title: "Hidden")
                    ])
                ])
            ])
        ])
        let result = findBestChild(in: root, maxDepth: 3)
        #expect(result == nil)
    }

    @Test func prefersPrimaryRoleOverMeaningfulContent() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXButton", title: "Click me"),
            MockElement(role: "AXGroup", title: "Has a title")
        ])
        let result = findBestChild(in: root)
        #expect(result?.role == "AXButton")
    }

    @Test func fallsBackToMeaningfulContent() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup"),
            MockElement(role: "AXGroup", title: "Important label")
        ])
        let result = findBestChild(in: root)
        #expect(result?.title == "Important label")
    }

    @Test func returnsNilForEmptyContainer() {
        let root = MockElement(role: "AXGroup", children: [])
        let result = findBestChild(in: root)
        #expect(result == nil)
    }

    @Test func returnsNilForNestedEmptyContainers() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [
                MockElement(role: "AXGroup", children: [])
            ])
        ])
        let result = findBestChild(in: root)
        #expect(result == nil)
    }

    @Test func hasMeaningfulContentWithTitle() {
        let node = MockElement(title: "Hello")
        #expect(hasMeaningfulContent(node) == true)
    }

    @Test func hasMeaningfulContentWithValue() {
        let node = MockElement(value: "typed text")
        #expect(hasMeaningfulContent(node) == true)
    }

    @Test func hasMeaningfulContentEmpty() {
        let node = MockElement()
        #expect(hasMeaningfulContent(node) == false)
    }

    @Test func scansUpToTwentyChildren() {
        var children: [any UIElementNode] = (0..<20).map { _ in
            MockElement(role: "AXGroup") as any UIElementNode
        }
        children.append(MockElement(role: "AXButton", title: "Hidden"))
        let root = MockElement(role: "AXGroup", children: children)
        let result = findBestChild(in: root)
        #expect(result == nil)
    }
}
