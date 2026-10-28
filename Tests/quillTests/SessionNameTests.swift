import Foundation
import Testing
@testable import quill

@Suite struct SessionNameTests {
    @Test func aCollisionSuffixStillNamesTheRecordingTime() {
        let root = URL(fileURLWithPath: "/recordings")
        let first = root.appendingPathComponent("2026.08.20-0943")
        let second = root.appendingPathComponent("2026.08.20-0943-2")
        #expect(SessionName.dated(first) != first.lastPathComponent)
        #expect(SessionName.dated(second) == SessionName.dated(first))
        #expect(SessionName.spoken(second) == SessionName.spoken(first))
    }

    @Test func aHandNamedFolderKeepsItsName() {
        let renamed = URL(fileURLWithPath: "/recordings/2026.08.24-1133-Karl-Meet")
        #expect(SessionName.dated(renamed) == "2026.08.24-1133-Karl-Meet")
        #expect(SessionName.dated(URL(fileURLWithPath: "/recordings/2026.08.24-1133-")) == "2026.08.24-1133-")
    }
}
