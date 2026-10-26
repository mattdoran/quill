import AppKit

/// A review window's buttons and delegate hold its controller weakly, so every
/// open review keeps its controller here until that window closes. Releasing
/// one early leaves a visible window that can neither save names nor close.
@MainActor
final class TranscriptReviewWindows {
    private var open: [String: VoiceReviewWindowController] = [:]

    func show(
        _ session: URL,
        make: () throws -> VoiceReviewWindowController
    ) rethrows {
        let key = session.standardizedFileURL.path
        if let controller = open[key] {
            controller.show()
            return
        }
        let controller = try make()
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, open[key] === controller else { return }
            open[key] = nil
            // AppKit is still closing the window this controller owns.
            DispatchQueue.main.async { withExtendedLifetime(controller) {} }
        }
        open[key] = controller
        controller.show()
    }
}
