public func shouldResumeSelectedPanelOnInvoke(
    isChatMode: Bool,
    isTaskIconMode: Bool
) -> Bool {
    isChatMode && !isTaskIconMode
}
