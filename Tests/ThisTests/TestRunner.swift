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
