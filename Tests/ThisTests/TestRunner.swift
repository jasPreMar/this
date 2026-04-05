import CoreGraphics
import Darwin
import ThisCore

// Simple test runner — prints results and exits with code 1 on failure.

var passed = 0
var failed = 0
var failures: [String] = []

func assert(_ condition: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        failures.append("  FAIL: \(name) (\(file):\(line))")
    }
}

// ─── Coordinate Conversion Tests ─────────────────────────────────────

func testCoordinateConversion() {
    let points1 = accessibilityQueryPoints(
        mouseLocation: CGPoint(x: 500, y: 300),
        screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
    )
    assert(points1.contains { $0.x == 500 && $0.y == 780 },
           "flipsYAxisForContainingScreen")
    assert(points1.contains { $0.x == 500 && $0.y == 300 },
           "includesOriginalCoordinate")
    assert(points1.count >= 2,
           "generatesMultiplePoints")

    let uniqueCount = Set(points1.map { "\($0.x),\($0.y)" }).count
    assert(points1.count == uniqueCount,
           "deduplicatesIdenticalPoints")

    let screens = [
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
        CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    ]
    let points2 = accessibilityQueryPoints(
        mouseLocation: CGPoint(x: 2000, y: 500),
        screenFrames: screens
    )
    assert(points2.contains { $0.x == 2000 && $0.y == 940 },
           "handlesMultipleScreens")
}

// ─── Role Set Tests ──────────────────────────────────────────────────

func testRoleSets() {
    assert(containerRoles.contains("AXGroup"), "containerRolesIncludesAXGroup")
    assert(containerRoles.contains("AXScrollArea"), "containerRolesIncludesAXScrollArea")
    assert(containerRoles.contains("AXSplitGroup"), "containerRolesIncludesAXSplitGroup")
    assert(primaryRoles.contains("AXButton"), "primaryRolesIncludesAXButton")
    assert(primaryRoles.contains("AXStaticText"), "primaryRolesIncludesAXStaticText")
    assert(!primaryRoles.contains("AXGroup"), "primaryRolesDoesNotIncludeAXGroup")
    assert(staleThreshold == 3, "staleThresholdIsThree")
}

// ─── Electron Group Drilling Tests ───────────────────────────────────

func testElectronGroupDrilling() {
    let root1 = MockElement(role: "AXGroup", children: [
        MockElement(role: "AXButton", title: "Save")
    ])
    let result1 = findBestChild(in: root1)
    assert(result1?.role == "AXButton", "findsBestChildInSingleLevelGroup_role")
    assert(result1?.title == "Save", "findsBestChildInSingleLevelGroup_title")

    let root2 = MockElement(role: "AXGroup", children: [
        MockElement(role: "AXGroup", children: [
            MockElement(role: "AXTextField", value: "hello")
        ])
    ])
    assert(findBestChild(in: root2)?.role == "AXTextField", "drillsTwoLevelsDeep")

    let root3 = MockElement(role: "AXGroup", children: [
        MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [
                MockElement(role: "AXButton", title: "OK")
            ])
        ])
    ])
    assert(findBestChild(in: root3)?.role == "AXButton", "drillsThreeLevelsDeep")

    let root4 = MockElement(role: "AXGroup", children: [
        MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [
                MockElement(role: "AXGroup", children: [
                    MockElement(role: "AXButton", title: "Hidden")
                ])
            ])
        ])
    ])
    assert(findBestChild(in: root4, maxDepth: 3) == nil, "stopsAtMaxDepth")

    let root5 = MockElement(role: "AXGroup", children: [
        MockElement(role: "AXButton", title: "Click me"),
        MockElement(role: "AXGroup", title: "Has a title")
    ])
    assert(findBestChild(in: root5)?.role == "AXButton", "prefersPrimaryRoleOverMeaningfulContent")

    let root6 = MockElement(role: "AXGroup", children: [
        MockElement(role: "AXGroup"),
        MockElement(role: "AXGroup", title: "Important label")
    ])
    assert(findBestChild(in: root6)?.title == "Important label", "fallsBackToMeaningfulContent")

    assert(findBestChild(in: MockElement(role: "AXGroup", children: [])) == nil,
           "returnsNilForEmptyContainer")

    let root7 = MockElement(role: "AXGroup", children: [
        MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [])
        ])
    ])
    assert(findBestChild(in: root7) == nil, "returnsNilForNestedEmptyContainers")

    assert(hasMeaningfulContent(MockElement(title: "Hello")) == true,
           "hasMeaningfulContentWithTitle")
    assert(hasMeaningfulContent(MockElement(value: "typed text")) == true,
           "hasMeaningfulContentWithValue")
    assert(hasMeaningfulContent(MockElement()) == false,
           "hasMeaningfulContentEmpty")

    var children: [any UIElementNode] = (0..<20).map { _ in
        MockElement(role: "AXGroup") as any UIElementNode
    }
    children.append(MockElement(role: "AXButton", title: "Hidden"))
    let root8 = MockElement(role: "AXGroup", children: children)
    assert(findBestChild(in: root8) == nil, "scansUpToTwentyChildren")
}

// ─── Fast Command Router Tests ──────────────────────────────────────

func testFastCommandRouter() {
    let classifier = RuleBasedFastCommandClassifier()
    let catalog = FastCommandCatalog(apps: [
        FastAppCandidate(name: "Finder", bundleIdentifier: "com.apple.finder", isRunning: true),
        FastAppCandidate(name: "Safari", bundleIdentifier: "com.apple.Safari", isRunning: true),
        FastAppCandidate(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", isRunning: true),
        FastAppCandidate(name: "Signal", bundleIdentifier: "org.signal.Signal", isRunning: false),
    ])

    let openFinder = classifier.decide(
        context: FastCommandContext(prompt: "open Finder", surface: .cursorPanel),
        catalog: catalog
    )
    if case .execute(let match) = openFinder {
        assert(match.action == .open, "routerOpenFinderAction")
        assert(match.executionPlan == .app(action: .open, target: .named("Finder")), "routerOpenFinderPlan")
        assert(match.confidence >= 0.95, "routerOpenFinderConfidence")
    } else {
        assert(false, "routerOpenFinderExecutes")
    }

    let implicitSafari = classifier.decide(
        context: FastCommandContext(prompt: "saf", surface: .commandMenu),
        catalog: catalog
    )
    if case .execute(let match) = implicitSafari {
        assert(match.executionPlan == .app(action: .open, target: .named("Safari")), "routerImplicitSafariPlan")
    } else {
        assert(false, "routerImplicitSafariExecutes")
    }

    let typoSafari = classifier.decide(
        context: FastCommandContext(prompt: "open safri", surface: .commandMenu),
        catalog: catalog
    )
    if case .execute(let match) = typoSafari {
        assert(match.executionPlan == .app(action: .open, target: .named("Safari")), "routerTypoSafariPlan")
    } else {
        assert(false, "routerTypoSafariExecutes")
    }

    let openHoveredFile = classifier.decide(
        context: FastCommandContext(
            prompt: "open this file",
            surface: .cursorPanel,
            hoveredFilePath: "/tmp/budget.xlsx",
            hoveredWorkingDirectoryPath: "/tmp"
        ),
        catalog: catalog
    )
    if case .execute(let match) = openHoveredFile {
        assert(match.executionPlan == .file(action: .open, target: .hoveredFile(pathHint: "/tmp/budget.xlsx")), "routerHoveredFilePlan")
    } else {
        assert(false, "routerHoveredFileExecutes")
    }

    let maximizeWindow = classifier.decide(
        context: FastCommandContext(
            prompt: "maximize this window",
            surface: .cursorPanel,
            invocationSnapshot: FastInvocationSnapshot(appName: "Safari", bundleIdentifier: "com.apple.Safari", windowTitle: "Docs")
        ),
        catalog: catalog
    )
    if case .execute(let match) = maximizeWindow {
        assert(match.executionPlan == .window(action: .maximize, target: .frontmost(appName: "Safari")), "routerMaximizeWindowPlan")
    } else {
        assert(false, "routerMaximizeWindowExecutes")
    }

    let findFile = classifier.decide(
        context: FastCommandContext(prompt: "find budget.xlsx", surface: .commandMenu),
        catalog: catalog
    )
    if case .execute(let match) = findFile {
        assert(match.executionPlan == .file(action: .reveal, target: .query("budget.xlsx")), "routerFindFilePlan")
    } else {
        assert(false, "routerFindFileExecutes")
    }

    let ambiguous = classifier.decide(
        context: FastCommandContext(prompt: "s", surface: .commandMenu),
        catalog: catalog
    )
    assert(ambiguous == .fallback(.ambiguousSubject), "routerAmbiguousSubjectFallsBack")

    let whySlow = classifier.decide(
        context: FastCommandContext(prompt: "why is Finder slow", surface: .cursorPanel),
        catalog: catalog
    )
    assert(whySlow == .fallback(.reasoningRequired), "routerReasoningFallsBack")

    let chained = classifier.decide(
        context: FastCommandContext(prompt: "open Finder and maximize it", surface: .cursorPanel),
        catalog: catalog
    )
    assert(chained == .fallback(.multiStep), "routerMultiStepFallsBack")

    let copyText = classifier.decide(
        context: FastCommandContext(prompt: "copy this text", surface: .cursorPanel),
        catalog: catalog
    )
    assert(copyText == .fallback(.textTransform), "routerCopyTextFallsBack")

    let fixError = classifier.decide(
        context: FastCommandContext(prompt: "fix this error", surface: .cursorPanel),
        catalog: catalog
    )
    assert(fixError == .fallback(.reasoningRequired), "routerFixFallsBack")

    let missingHover = classifier.decide(
        context: FastCommandContext(prompt: "open this file", surface: .cursorPanel),
        catalog: catalog
    )
    assert(missingHover == .fallback(.noSubject), "routerMissingHoverFallsBack")

    let commandMenuHomeSeed = classifier.decide(
        context: FastCommandContext(
            prompt: "open this file",
            surface: .commandMenu,
            hoveredWorkingDirectoryPath: "/Users/tester",
            allowsDeicticFileTarget: false
        ),
        catalog: catalog
    )
    assert(commandMenuHomeSeed == .fallback(.noSubject), "routerCommandMenuHomeSeedFallsBack")

    let commandMenuCopySeed = classifier.decide(
        context: FastCommandContext(
            prompt: "copy this path",
            surface: .commandMenu,
            hoveredWorkingDirectoryPath: "/Users/tester",
            allowsDeicticFileTarget: false
        ),
        catalog: catalog
    )
    assert(commandMenuCopySeed == .fallback(.noSubject), "routerCommandMenuCopySeedFallsBack")
}

// ─── Panel Invocation Tests ────────────────────────────────────────

func testPanelInvocationPolicy() {
    assert(
        shouldResumeSelectedPanelOnInvoke(isChatMode: true, isTaskIconMode: false) == true,
        "resumesVisibleChatPanel"
    )
    assert(
        shouldResumeSelectedPanelOnInvoke(isChatMode: true, isTaskIconMode: true) == false,
        "doesNotResumeTaskIconPanel"
    )
    assert(
        shouldResumeSelectedPanelOnInvoke(isChatMode: false, isTaskIconMode: false) == false,
        "doesNotResumeSearchPanel"
    )
}

// ─── Assistant Response Directive Tests ─────────────────────────────

func testAssistantResponseDirectives() {
    let revealText = AssistantResponseDirectiveParser.parse("""
    Finished opening Finder.
    [[HP_COMMAND_MENU:REVEAL]]
    """)
    assert(revealText.sanitizedText == "Finished opening Finder.",
           "revealDirectiveSanitizesPlainText")
    assert(revealText.completionAction == .reveal,
           "revealDirectiveParsesRevealAction")
    assert(revealText.hasExplicitDirective,
           "revealDirectiveIsExplicit")

    let preserveText = AssistantResponseDirectiveParser.parse("""
    Moved the file into Downloads.
    [[HP_COMMAND_MENU:PRESERVE]]
    """)
    assert(preserveText.sanitizedText == "Moved the file into Downloads.",
           "preserveDirectiveSanitizesPlainText")
    assert(preserveText.completionAction == .preserve,
           "preserveDirectiveParsesPreserveAction")
    assert(preserveText.hasExplicitDirective,
           "preserveDirectiveIsExplicit")

    let noDirective = AssistantResponseDirectiveParser.parse("Opened Notes.")
    assert(noDirective.sanitizedText == "Opened Notes.",
           "missingDirectiveLeavesTextUntouched")
    assert(noDirective.completionAction == .reveal,
           "missingDirectiveDefaultsToReveal")
    assert(!noDirective.hasExplicitDirective,
           "missingDirectiveIsNotExplicit")

    let malformedDirective = AssistantResponseDirectiveParser.parse("""
    Opened Calculator.
    [[HP_COMMAND_MENU:SOMETHING_ELSE]]
    """)
    assert(malformedDirective.sanitizedText == "Opened Calculator.",
           "malformedDirectiveIsStripped")
    assert(malformedDirective.completionAction == .reveal,
           "malformedDirectiveDefaultsToReveal")
    assert(!malformedDirective.hasExplicitDirective,
           "malformedDirectiveIsNotExplicit")

    let structuredReveal = AssistantResponseDirectiveParser.parse("""
    {"_hpCommandMenu":"reveal","layout":{"type":"text","content":"Done"},"spoken_summary":"Done","title":"Task"}
    """)
    assert(structuredReveal.completionAction == .reveal,
           "structuredRevealParsesRevealAction")
    assert(structuredReveal.hasExplicitDirective,
           "structuredRevealIsExplicit")
    assert(!structuredReveal.sanitizedText.contains("_hpCommandMenu"),
           "structuredRevealRemovesMetadataKey")

    let structuredPreserve = AssistantResponseDirectiveParser.parse("""
    {"_hpCommandMenu":"preserve","layout":{"type":"text","content":"Done"},"spoken_summary":"Done","title":"Task"}
    """)
    assert(structuredPreserve.completionAction == .preserve,
           "structuredPreserveParsesPreserveAction")
    assert(structuredPreserve.hasExplicitDirective,
           "structuredPreserveIsExplicit")
    assert(!structuredPreserve.sanitizedText.contains("_hpCommandMenu"),
           "structuredPreserveRemovesMetadataKey")

    let structuredWithPreamble = AssistantResponseDirectiveParser.parse("""
    Sure.
    {"_hpCommandMenu":"reveal","layout":{"type":"text","content":"Done"},"spoken_summary":"Done","title":"Task"}
    """)
    assert(structuredWithPreamble.completionAction == .reveal,
           "structuredWithPreambleParsesRevealAction")
    assert(structuredWithPreamble.hasExplicitDirective,
           "structuredWithPreambleIsExplicit")
    assert(structuredWithPreamble.sanitizedText.hasPrefix("{"),
           "structuredWithPreambleExtractsJSONObject")
    assert(!structuredWithPreamble.sanitizedText.contains("_hpCommandMenu"),
           "structuredWithPreambleRemovesMetadataKey")

    assert(shouldRevealCommandMenuOnCompletion(
        isEligibleForReveal: true,
        completionAction: .reveal,
        isCommandMenuVisible: false,
        isCommandMenuDismissing: false
    ), "revealPolicyShowsWhenMenuIsClosed")

    assert(!shouldRevealCommandMenuOnCompletion(
        isEligibleForReveal: true,
        completionAction: .reveal,
        isCommandMenuVisible: true,
        isCommandMenuDismissing: false
    ), "revealPolicyDoesNotStealVisibleMenu")

    assert(shouldRevealCommandMenuOnCompletion(
        isEligibleForReveal: true,
        completionAction: .reveal,
        isCommandMenuVisible: true,
        isCommandMenuDismissing: true
    ), "revealPolicyShowsDuringDismissAnimation")

    assert(!shouldRevealCommandMenuOnCompletion(
        isEligibleForReveal: false,
        completionAction: .reveal,
        isCommandMenuVisible: false,
        isCommandMenuDismissing: false
    ), "revealPolicyRequiresEligibility")

    assert(!shouldRevealCommandMenuOnCompletion(
        isEligibleForReveal: true,
        completionAction: .preserve,
        isCommandMenuVisible: false,
        isCommandMenuDismissing: false
    ), "revealPolicyHonorsPreserve")

    assert(!shouldMarkCompletedTaskUnread(
        completionAction: .preserve,
        isTaskVisibleToUser: false
    ), "preserveCompletionDoesNotCreateUnreadTask")

    assert(shouldMarkCompletedTaskUnread(
        completionAction: .reveal,
        isTaskVisibleToUser: false
    ), "revealCompletionMarksHiddenTaskUnread")

    assert(shouldAutoDismissFloatingPanelOnCompletion(
        completionAction: .preserve,
        isTaskIconMode: true
    ), "preserveCompletionDismissesTaskIcon")

    assert(!shouldAutoDismissFloatingPanelOnCompletion(
        completionAction: .reveal,
        isTaskIconMode: true
    ), "revealCompletionKeepsTaskIconVisible")

    assert(!shouldAutoDismissFloatingPanelOnCompletion(
        completionAction: .preserve,
        isTaskIconMode: false
    ), "preserveCompletionOnlyDismissesTaskIconMode")

    assert(shouldMarkTaskEligibleForClosedCommandMenuReveal(
        isCommandMenuVisible: false
    ), "hiddenCommandMenuMarksTaskEligibleForReveal")

    assert(!shouldMarkTaskEligibleForClosedCommandMenuReveal(
        isCommandMenuVisible: true
    ), "visibleCommandMenuDoesNotMarkTaskEligibleForReveal")
}

// ─── Command Menu Presentation Policy Tests ──────────────────────────

func testCommandMenuPresentationPolicy() {
    assert(
        commandMenuSpaceAffinity(isPinned: false) == .currentSpaceOnly,
        "unpinnedCommandMenuUsesCurrentSpaceOnly"
    )
    assert(
        commandMenuSpaceAffinity(isPinned: true) == .allSpaces,
        "pinnedCommandMenuUsesAllSpaces"
    )

    assert(
        shouldDismissCommandMenuOnActiveSpaceChange(
            isPinned: false,
            isCommandMenuVisible: true,
            isCommandMenuDismissing: false
        ),
        "activeSpaceChangeDismissesVisibleUnpinnedMenu"
    )
    assert(
        !shouldDismissCommandMenuOnActiveSpaceChange(
            isPinned: true,
            isCommandMenuVisible: true,
            isCommandMenuDismissing: false
        ),
        "activeSpaceChangeDoesNotDismissPinnedMenu"
    )
    assert(
        !shouldDismissCommandMenuOnActiveSpaceChange(
            isPinned: false,
            isCommandMenuVisible: false,
            isCommandMenuDismissing: false
        ),
        "activeSpaceChangeIgnoresHiddenMenu"
    )
    assert(
        !shouldDismissCommandMenuOnActiveSpaceChange(
            isPinned: false,
            isCommandMenuVisible: true,
            isCommandMenuDismissing: true
        ),
        "activeSpaceChangeIgnoresAlreadyDismissingMenu"
    )

    let bounds = commandMenuManualHeightBounds(
        screenHeight: 900,
        bottomMargin: 80,
        chromeHeight: 210,
        minimumVisibleChatHeight: 120
    )
    assert(bounds == CommandMenuManualHeightBounds(
        minimumTotalHeight: 330,
        maximumTotalHeight: 740
    ), "commandMenuHeightBoundsUseScreenChromeAndChatMinimums")

    assert(
        clampedCommandMenuManualHeight(280, bounds: bounds) == 330,
        "commandMenuHeightClampHonorsMinimum"
    )
    assert(
        clampedCommandMenuManualHeight(500, bounds: bounds) == 500,
        "commandMenuHeightClampKeepsInRangeValues"
    )
    assert(
        clampedCommandMenuManualHeight(800, bounds: bounds) == 740,
        "commandMenuHeightClampHonorsMaximum"
    )
    assert(
        commandMenuManualHeightAfterDrag(
            startHeight: 500,
            dragDeltaY: 120,
            bounds: bounds
        ) == 620,
        "draggingHeaderUpIncreasesHeightOneToOne"
    )
    assert(
        commandMenuManualHeightAfterDrag(
            startHeight: 500,
            dragDeltaY: -90,
            bounds: bounds
        ) == 410,
        "draggingHeaderDownDecreasesHeightOneToOne"
    )
    assert(
        commandMenuStartingSurfaceHeight(
            reportedTotalHeight: 0,
            chromeHeight: 160,
            chatViewportHeight: 420
        ) == 580,
        "startingSurfaceHeightUsesMeasuredViewportWhenTotalFrameIsUnavailable"
    )
    assert(
        commandMenuStartingSurfaceHeight(
            reportedTotalHeight: 640,
            chromeHeight: 160,
            chatViewportHeight: 420
        ) == 640,
        "startingSurfaceHeightPrefersReportedTotalHeight"
    )
    assert(
        commandMenuStartingSurfaceHeight(
            reportedTotalHeight: 0,
            chromeHeight: 160,
            chatViewportHeight: 0
        ) == nil,
        "startingSurfaceHeightWaitsForRealMeasurementsInsteadOfUsingMinimumFallback"
    )

    assert(
        commandMenuPinnedHeightModeAfterPinChange(.manual(totalHeight: 480), isPinned: false) == .automatic,
        "turningPinOffClearsManualHeightMode"
    )
    assert(
        commandMenuPinnedHeightModeAfterPinChange(.manual(totalHeight: 480), isPinned: true) == .manual(totalHeight: 480),
        "keepingPinOnPreservesManualHeightMode"
    )

    assert(
        canResizePinnedCommandMenuHeight(
            isPinned: true,
            hasLiveChat: true,
            isCommandMenuDismissing: false
        ),
        "pinnedLiveChatCanResizeHeight"
    )
    assert(
        !canResizePinnedCommandMenuHeight(
            isPinned: false,
            hasLiveChat: true,
            isCommandMenuDismissing: false
        ),
        "unpinnedMenuCannotResizeHeight"
    )
    assert(
        !canResizePinnedCommandMenuHeight(
            isPinned: true,
            hasLiveChat: false,
            isCommandMenuDismissing: false
        ),
        "draftOrMinimizedMenuCannotResizeHeight"
    )
    assert(
        !canResizePinnedCommandMenuHeight(
            isPinned: true,
            hasLiveChat: true,
            isCommandMenuDismissing: true
        ),
        "dismissingMenuCannotResizeHeight"
    )

    assert(
        shouldShowCommandMenuHeightResetControl(
            isPinned: true,
            hasLiveChat: true,
            heightMode: .manual(totalHeight: 500),
            isCommandMenuDismissing: false
        ),
        "manualPinnedLiveChatShowsResetControl"
    )
    assert(
        !shouldShowCommandMenuHeightResetControl(
            isPinned: true,
            hasLiveChat: true,
            heightMode: .automatic,
            isCommandMenuDismissing: false
        ),
        "automaticHeightHidesResetControl"
    )
    assert(
        !shouldShowCommandMenuHeightResetControl(
            isPinned: true,
            hasLiveChat: false,
            heightMode: .manual(totalHeight: 500),
            isCommandMenuDismissing: false
        ),
        "draftOrMinimizedStateHidesResetControl"
    )
}

// ─── Entry Point ─────────────────────────────────────────────────────

func output(_ s: String) {
    var line = s + "\n"
    line.withUTF8 { buf in
        _ = Darwin.write(STDOUT_FILENO, buf.baseAddress!, buf.count)
    }
}

@main
struct RegressionTests {
    static func main() {
        testCoordinateConversion()
        testRoleSets()
        testElectronGroupDrilling()
        testFastCommandRouter()
        testPanelInvocationPolicy()
        testAssistantResponseDirectives()
        testCommandMenuPresentationPolicy()

        output("")
        output("━━━ Regression Tests ━━━")
        output("  \(passed) passed, \(failed) failed")
        if !failures.isEmpty {
            output("")
            for f in failures { output(f) }
            output("")
        }
        output("━━━━━━━━━━━━━━━━━━━━━━━")
        output("")

        _Exit(failed > 0 ? 1 : 0)
    }
}
