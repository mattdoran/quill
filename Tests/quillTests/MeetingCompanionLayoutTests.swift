import AppKit
import Foundation
import Testing
@testable import quill

@MainActor
@Suite struct MeetingCompanionLayoutTests {
    @Test func everyVisibleControlFitsAtTheSupportedPanelSize() {
        _ = NSApplication.shared
        let application = CallApplication(
            id: "teams",
            name: "Microsoft Teams (Work or School) for Contoso Engineering"
        )
        let states: [MeetingCompanionState.Phase] = [
            .detected(application: application, token: UUID()),
            .starting(application: application),
            .recording(application: application, elapsed: "12:34:56"),
            .possibleEnd(application: application, elapsed: "12:34:56", remaining: autoStopGrace),
            .finalizing,
            .processing,
            .ready(session: URL(fileURLWithPath: "/tmp/2026.08.19-1432")),
        ]

        for state in states {
            let view = MeetingCompanionView(
                frame: NSRect(
                    origin: .zero,
                    size: MeetingCompanionController.expandedSize(for: state)
                )
            )
            view.render(state)
            view.layoutSubtreeIfNeeded()
            #expect(view.visibleControlsFitBounds(), "controls escaped in \(state)")
            #expect(!view.titleIsTruncated(), "title truncated in \(state)")
        }

        let collapsed = MeetingCompanionView(
            frame: NSRect(origin: .zero, size: MeetingCompanionController.collapsedSize)
        )
        collapsed.renderCollapsed(elapsed: "12:34:56")
        collapsed.layoutSubtreeIfNeeded()
        #expect(collapsed.visibleControlsFitBounds())
        #expect(collapsed.hitTest(NSPoint(x: 4, y: 4)) === collapsed)
    }

    @Test func reduceMotionDisablesTheDetectionCountdownAnimation() {
        _ = NSApplication.shared
        let application = CallApplication(id: "teams", name: "Microsoft Teams")
        let view = MeetingCompanionView(
            frame: NSRect(origin: .zero, size: MeetingCompanionController.expandedSize)
        )

        view.applyAccessibilityOptions(
            reduceTransparency: false,
            increaseContrast: false,
            reduceMotion: true
        )
        view.render(.detected(application: application, token: UUID()))
        #expect(!view.detectionCountdownIsAnimating())

        view.applyAccessibilityOptions(
            reduceTransparency: false,
            increaseContrast: false,
            reduceMotion: false
        )
        view.render(.detected(application: application, token: UUID()))
        #expect(view.detectionCountdownIsAnimating())
    }

    @Test func autoStopCountdownAnimatesOnceAndSurvivesTicks() {
        _ = NSApplication.shared
        let application = CallApplication(id: "zoom", name: "Zoom")
        let view = MeetingCompanionView(
            frame: NSRect(
                origin: .zero,
                size: MeetingCompanionController.possibleEndSize
            )
        )
        view.applyAccessibilityOptions(
            reduceTransparency: false,
            increaseContrast: false,
            reduceMotion: false
        )
        let entering = MeetingCompanionState.Phase.possibleEnd(
            application: application, elapsed: "12:34", remaining: autoStopGrace
        )
        view.render(entering)
        #expect(view.autoStopCountdownIsAnimating())

        // A per-second tick must not restart it, or the bar jumps backwards.
        let animation = view.timeoutBarAnimation()
        view.render(.possibleEnd(
            application: application, elapsed: "12:35", remaining: autoStopGrace - 1
        ))
        #expect(view.timeoutBarAnimation() === animation)

        view.render(.recording(application: application, elapsed: "12:36"))
        #expect(!view.autoStopCountdownIsAnimating())
    }

    @Test func autoStopCountdownHidesTheBarUnderReduceMotion() {
        _ = NSApplication.shared
        let application = CallApplication(id: "zoom", name: "Zoom")
        let view = MeetingCompanionView(
            frame: NSRect(
                origin: .zero,
                size: MeetingCompanionController.possibleEndSize
            )
        )
        view.applyAccessibilityOptions(
            reduceTransparency: false,
            increaseContrast: false,
            reduceMotion: true
        )
        view.render(.possibleEnd(
            application: application, elapsed: "12:34", remaining: autoStopGrace
        ))

        #expect(!view.autoStopCountdownIsAnimating())
        #expect(!view.timeoutBarIsVisible())
    }

    @Test func materialUsesAnExplicitRoundedMask() throws {
        _ = NSApplication.shared
        let view = MeetingCompanionView(
            frame: NSRect(origin: .zero, size: MeetingCompanionController.expandedSize)
        )
        view.layoutSubtreeIfNeeded()

        let data = try #require(view.maskImage?.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        #expect(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                .alphaComponent == 1
        )
    }
}
