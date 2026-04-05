import CoreGraphics

public enum CommandMenuSpaceAffinity: Equatable {
    case currentSpaceOnly
    case allSpaces
}

public enum CommandMenuPinnedHeightMode: Equatable {
    case automatic
    case manual(totalHeight: CGFloat)
}

public struct CommandMenuManualHeightBounds: Equatable {
    public let minimumTotalHeight: CGFloat
    public let maximumTotalHeight: CGFloat

    public init(
        minimumTotalHeight: CGFloat,
        maximumTotalHeight: CGFloat
    ) {
        self.minimumTotalHeight = minimumTotalHeight
        self.maximumTotalHeight = max(minimumTotalHeight, maximumTotalHeight)
    }
}

public func commandMenuSpaceAffinity(isPinned: Bool) -> CommandMenuSpaceAffinity {
    isPinned ? .allSpaces : .currentSpaceOnly
}

public func shouldDismissCommandMenuOnActiveSpaceChange(
    isPinned: Bool,
    isCommandMenuVisible: Bool,
    isCommandMenuDismissing: Bool
) -> Bool {
    !isPinned && isCommandMenuVisible && !isCommandMenuDismissing
}

public func commandMenuManualHeightBounds(
    screenHeight: CGFloat,
    bottomMargin: CGFloat,
    chromeHeight: CGFloat,
    minimumVisibleChatHeight: CGFloat
) -> CommandMenuManualHeightBounds {
    CommandMenuManualHeightBounds(
        minimumTotalHeight: chromeHeight + minimumVisibleChatHeight,
        maximumTotalHeight: screenHeight - (bottomMargin * 2)
    )
}

public func clampedCommandMenuManualHeight(
    _ proposedHeight: CGFloat,
    bounds: CommandMenuManualHeightBounds
) -> CGFloat {
    min(max(proposedHeight, bounds.minimumTotalHeight), bounds.maximumTotalHeight)
}

public func commandMenuManualHeightAfterDrag(
    startHeight: CGFloat,
    dragDeltaY: CGFloat,
    bounds: CommandMenuManualHeightBounds
) -> CGFloat {
    clampedCommandMenuManualHeight(
        startHeight + dragDeltaY,
        bounds: bounds
    )
}

public func commandMenuStartingSurfaceHeight(
    reportedTotalHeight: CGFloat,
    chromeHeight: CGFloat,
    chatViewportHeight: CGFloat
) -> CGFloat? {
    if reportedTotalHeight > 0 {
        return reportedTotalHeight
    }

    if chromeHeight > 0, chatViewportHeight > 0 {
        return chromeHeight + chatViewportHeight
    }

    return nil
}

public func commandMenuPinnedHeightModeAfterPinChange(
    _ currentMode: CommandMenuPinnedHeightMode,
    isPinned: Bool
) -> CommandMenuPinnedHeightMode {
    guard isPinned else { return .automatic }
    return currentMode
}

public func canResizePinnedCommandMenuHeight(
    isPinned: Bool,
    hasLiveChat: Bool,
    isCommandMenuDismissing: Bool
) -> Bool {
    isPinned && hasLiveChat && !isCommandMenuDismissing
}

public func shouldShowCommandMenuHeightResetControl(
    isPinned: Bool,
    hasLiveChat: Bool,
    heightMode: CommandMenuPinnedHeightMode,
    isCommandMenuDismissing: Bool
) -> Bool {
    guard canResizePinnedCommandMenuHeight(
        isPinned: isPinned,
        hasLiveChat: hasLiveChat,
        isCommandMenuDismissing: isCommandMenuDismissing
    ) else {
        return false
    }

    if case .manual = heightMode {
        return true
    }

    return false
}
