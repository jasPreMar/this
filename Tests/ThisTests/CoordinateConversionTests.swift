import Testing
import CoreGraphics
@testable import ThisCore

@Suite("Coordinate Conversion")
struct CoordinateConversionTests {

    @Test func flipsYAxisForContainingScreen() {
        let points = accessibilityQueryPoints(
            mouseLocation: CGPoint(x: 500, y: 300),
            screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        )
        #expect(points.contains { $0.x == 500 && $0.y == 780 })
    }

    @Test func includesOriginalCoordinate() {
        let points = accessibilityQueryPoints(
            mouseLocation: CGPoint(x: 500, y: 300),
            screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        )
        #expect(points.contains { $0.x == 500 && $0.y == 300 })
    }

    @Test func generatesMultiplePoints() {
        let points = accessibilityQueryPoints(
            mouseLocation: CGPoint(x: 500, y: 300),
            screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        )
        #expect(points.count >= 2)
    }

    @Test func handlesMultipleScreens() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        ]
        let points = accessibilityQueryPoints(
            mouseLocation: CGPoint(x: 2000, y: 500),
            screenFrames: screens
        )
        // Should flip Y relative to the screen containing the point (second screen)
        #expect(points.contains { $0.x == 2000 && $0.y == 940 }) // 1440 - 500
    }

    @Test func deduplicatesIdenticalPoints() {
        let points = accessibilityQueryPoints(
            mouseLocation: CGPoint(x: 500, y: 300),
            screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        )
        let uniqueCount = Set(points.map { "\($0.x),\($0.y)" }).count
        #expect(points.count == uniqueCount)
    }
}
