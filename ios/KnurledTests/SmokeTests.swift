import Testing
@testable import Knurled

@Suite struct SmokeTests {
    @Test func appTabsAreDistinct() {
        #expect(AppTab.workout != AppTab.history)
    }
}
