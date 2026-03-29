import Foundation

// MARK: - Testable element protocol

/// Protocol abstracting AXUIElement so tests can use mock elements.
public protocol UIElementNode {
    var role: String? { get }
    var title: String? { get }
    var elementDescription: String? { get }
    var value: String? { get }
    var selectedText: String? { get }
    var children: [any UIElementNode] { get }
}

// MARK: - Role sets

/// Interactive/item-level roles — use as primary element.
public let primaryRoles: Set<String> = [
    "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox",
    "AXRadioButton", "AXSlider", "AXPopUpButton", "AXComboBox",
    "AXMenuItem", "AXMenuBarItem", "AXTab", "AXCell", "AXRow",
    "AXHeading", "AXDockItem", "AXDisclosureTriangle",
    "AXColorWell", "AXIncrementor",
    "AXStaticText", "AXImage"
]

/// Container roles — good as ancestor context but too broad as primary.
public let containerRoles: Set<String> = [
    "AXList", "AXTable", "AXOutline", "AXToolbar", "AXTabGroup",
    "AXScrollArea", "AXSplitGroup", "AXGroup"
]

/// Threshold for stale accessibility tree detection.
public let staleThreshold = 3
