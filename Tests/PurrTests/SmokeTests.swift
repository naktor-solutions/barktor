import Testing

@testable import Purr

struct SmokeTests {
    @Test func testTargetLinksAgainstApp() {
        // SettingsStore.Engine is a plain enum - referencing it proves the
        // executable target links into the test bundle.
        #expect(SettingsStore.Engine.allCases.contains(.parakeet))
    }
}
