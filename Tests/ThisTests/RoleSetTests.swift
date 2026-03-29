import Testing
@testable import ThisCore

@Suite("Role Sets")
struct RoleSetTests {

    @Test func containerRolesIncludesAXGroup() {
        #expect(containerRoles.contains("AXGroup"))
    }

    @Test func containerRolesIncludesAXScrollArea() {
        #expect(containerRoles.contains("AXScrollArea"))
    }

    @Test func containerRolesIncludesAXSplitGroup() {
        #expect(containerRoles.contains("AXSplitGroup"))
    }

    @Test func primaryRolesIncludesAXButton() {
        #expect(primaryRoles.contains("AXButton"))
    }

    @Test func primaryRolesIncludesAXStaticText() {
        #expect(primaryRoles.contains("AXStaticText"))
    }

    @Test func primaryRolesDoesNotIncludeAXGroup() {
        #expect(!primaryRoles.contains("AXGroup"))
    }

    @Test func staleThresholdIsThree() {
        #expect(staleThreshold == 3)
    }
}
