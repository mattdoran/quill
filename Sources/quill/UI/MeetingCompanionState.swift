import Foundation

struct MeetingCompanionState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case hidden
        case detected(application: CallApplication, token: UUID)
        case starting(application: CallApplication?)
        case recording(application: CallApplication?, elapsed: String)
        case possibleEnd(application: CallApplication, elapsed: String)
        case finalizing
        case processing
        case ready(transcript: URL)
        case failed(message: String)
    }

    enum Event: Equatable, Sendable {
        case callDetected(CallApplication, token: UUID)
        case callEnded(CallApplication)
        case callRecovered(CallApplication)
        case keepRecording
        case startRequested(CallApplication?)
        case recordingStarted(CallApplication?)
        case elapsed(String)
        case stopRequested
        case finalizationFinished
        case transcriptReady(URL)
        case failed(String)
        case dismissed
        case showControls
        case reset
    }

    private(set) var phase: Phase = .hidden
    private(set) var suppressedApplication: CallApplication?
    private(set) var wasDismissedDuringSession = false
    private var dismissedLivePhase: Phase?

    mutating func handle(_ event: Event) {
        switch event {
        case .callDetected(let application, let token):
            guard suppressedApplication != application else { return }
            guard dismissedLivePhase == nil else { return }
            guard case .hidden = phase else { return }
            phase = .detected(application: application, token: token)

        case .callEnded(let application):
            if suppressedApplication == application {
                suppressedApplication = nil
            }
            switch phase {
            case .detected(let detected, _) where detected == application:
                phase = .hidden
            case .recording(let bound, let elapsed)
                where bound == application:
                phase = .possibleEnd(application: application, elapsed: elapsed)
            default:
                if
                    case .recording(let bound, let elapsed) =
                        dismissedLivePhase,
                    bound == application
                {
                    dismissedLivePhase = .possibleEnd(application: application, elapsed: elapsed)
                }
            }

        case .callRecovered(let application):
            if
                case .possibleEnd(let bound, let elapsed) = phase,
                bound == application
            {
                phase = .recording(application: application, elapsed: elapsed)
            } else if
                case .possibleEnd(let bound, let elapsed) =
                    dismissedLivePhase,
                bound == application
            {
                dismissedLivePhase = .recording(application: application, elapsed: elapsed)
            }

        case .keepRecording:
            guard
                case .possibleEnd(let application, let elapsed) = phase
            else { return }
            phase = .recording(application: application, elapsed: elapsed)

        case .startRequested(let application):
            wasDismissedDuringSession = false
            phase = .starting(application: application)

        case .recordingStarted(let application):
            phase = .recording(application: application, elapsed: "0:00")

        case .elapsed(let elapsed):
            switch phase {
            case .recording(let application, _):
                phase = .recording(application: application, elapsed: elapsed)
            case .possibleEnd(let application, _):
                phase = .possibleEnd(application: application, elapsed: elapsed)
            default:
                dismissedLivePhase = dismissedLivePhase?.updatingElapsed(elapsed)
            }

        case .stopRequested:
            if dismissedLivePhase?.isLiveRecording == true {
                dismissedLivePhase = nil
                return
            }
            guard phase.isLiveRecording else { return }
            phase = .finalizing

        case .finalizationFinished:
            guard case .finalizing = phase else { return }
            phase = .processing

        case .transcriptReady(let transcript):
            guard !wasDismissedDuringSession else { return }
            phase = .ready(transcript: transcript)

        case .failed(let message):
            guard !wasDismissedDuringSession else { return }
            phase = .failed(message: message)

        case .dismissed:
            switch phase {
            case .detected(let application, _):
                suppressedApplication = application
            case .starting, .recording, .possibleEnd, .finalizing, .processing:
                wasDismissedDuringSession = true
                if phase.isLiveRecording {
                    dismissedLivePhase = phase
                }
            case .hidden, .ready, .failed:
                break
            }
            phase = .hidden

        case .showControls:
            guard let dismissedLivePhase, dismissedLivePhase.isLiveRecording else { return }
            phase = dismissedLivePhase
            self.dismissedLivePhase = nil

        case .reset:
            phase = .hidden
            suppressedApplication = nil
            wasDismissedDuringSession = false
            dismissedLivePhase = nil
        }
    }
}

private extension MeetingCompanionState.Phase {
    var isLiveRecording: Bool {
        switch self {
        case .recording, .possibleEnd:
            true
        default:
            false
        }
    }

    func updatingElapsed(_ elapsed: String) -> Self {
        switch self {
        case .recording(let application, _):
            .recording(application: application, elapsed: elapsed)
        case .possibleEnd(let application, _):
            .possibleEnd(application: application, elapsed: elapsed)
        default:
            self
        }
    }
}
