import ThisCore

struct MockElement: UIElementNode {
    var role: String?
    var title: String?
    var elementDescription: String?
    var value: String?
    var selectedText: String?
    var children: [any UIElementNode]

    init(
        role: String? = nil,
        title: String? = nil,
        elementDescription: String? = nil,
        value: String? = nil,
        selectedText: String? = nil,
        children: [any UIElementNode] = []
    ) {
        self.role = role
        self.title = title
        self.elementDescription = elementDescription
        self.value = value
        self.selectedText = selectedText
        self.children = children
    }
}
