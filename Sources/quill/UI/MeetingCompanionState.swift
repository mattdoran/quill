import Foundation

struct MeetingCompanionState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case hidden
        case detected(application: CallApplication, token: UUID)
        case starting(application: CallApplication?)
        case recording(
            application: CallApplication?,
            elapsed: String,
            profile: MeetingProfile,
            voiceControlVisible: Bool
        )
        case possibleEnd(
            application: CallApplication,
            elapsed: String,
            profile: MeetingProfile,
            voiceControlVisible: Bool
        )
        case finalizing
        case processing
        case ready(transcript: URL)
        case failed(message: String)
    }

    enum Event: Equatable, Sendable {
        case callDetected(CallApplication, token: UUID)
        case callEnded(CallApplication)
        case callRecovered(CallApplication)
        case startRequested(CallApplication?)
        case recordingStarted(CallApplication?, profile: MeetingProfile)
        case elapsed(String)
        case profileChanged(MeetingProfile)
        case stopRequested
        case finalizationFinished(transcriptionEnabled: Bool)
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
            case .recording(let bound, let elapsed, let profile, let visible)
                where bound == application:
                phase = .possibleEnd(
                    application: application,
                    elapsed: elapsed,
                    profile: profile,
                    voiceControlVisible: visible
                )
            default:
                if
                    case .recording(let bound, let elapsed, let profile, let visible) =
                        dismissedLivePhase,
                    bound == application
                {
                    dismissedLivePhase = .possibleEnd(
                        application: application,
                        elapsed: elapsed,
                        profile: profile,
                        voiceControlVisible: visible
                    )
                }
            }

        case .callRecovered(let application):
            if
                case .possibleEnd(let bound, let elapsed, let profile, let visible) = phase,
                bound == application
            {
                phase = .recording(
                    application: application,
                    elapsed: elapsed,
                    profile: profile,
                    voiceControlVisible: visible
                )
            } else if
                case .possibleEnd(let bound, let elapsed, let profile, let visible) =
                    dismissedLivePhase,
                bound == application
            {
                dismissedLivePhase = .recording(
                    application: application,
                    elapsed: elapsed,
                    profile: profile,
                    voiceControlVisible: visible
                )
            }

        case .startRequested(let application):
            wasDismissedDuringSession = false
            phase = .starting(application: application)

        case .recordingStarted(let application, let profile):
            phase = .recording(
                application: application,
                elapsed: "0:00",
                profile: profile,
                voiceControlVisible: profile != .neither
            )

        case .elapsed(let elapsed):
            switch phase {
            case .recording(let application, _, let profile, let visible):
                phase = .recording(
                    application: application,
                    elapsed: elapsed,
                    profile: profile,
                    voiceControlVisible: visible
                )
            case .possibleEnd(let application, _, let profile, let visible):
                phase = .possibleEnd(
                    application: application,
                    elapsed: elapsed,
                    profile: profile,
                    voiceControlVisible: visible
                )
            default:
                dismissedLivePhase = dismissedLivePhase?.updatingElapsed(elapsed)
            }

        case .profileChanged(let profile):
            switch phase {
            case .recording(let application, let elapsed, _, _):
                phase = .recording(
                    application: application,
                    elapsed: elapsed,
                    profile: profile,
                    voiceControlVisible: true
                )
            case .possibleEnd(let application, let elapsed, _, _):
                phase = .possibleEnd(
                    application: application,
                    elapsed: elapsed,
                    profile: profile,
                    voiceControlVisible: true
                )
            default:
                dismissedLivePhase = dismissedLivePhase?.updatingProfile(profile)
            }

        case .stopRequested:
            if dismissedLivePhase?.isLiveRecording == true {
                dismissedLivePhase = nil
                return
            }
            guard phase.isLiveRecording else { return }
            phase = .finalizing

        case .finalizationFinished(let transcriptionEnabled):
            guard case .finalizing = phase else { return }
            phase = transcriptionEnabled ? .processing : .hidden

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
        case .recording(let application, _, let profile, let visible):
            .recording(
                application: application,
                elapsed: elapsed,
                profile: profile,
                voiceControlVisible: visible
            )
        case .possibleEnd(let application, _, let profile, let visible):
            .possibleEnd(
                application: application,
                elapsed: elapsed,
                profile: profile,
                voiceControlVisible: visible
            )
        default:
            self
        }
    }

    func updatingProfile(_ profile: MeetingProfile) -> Self {
        switch self {
        case .recording(let application, let elapsed, _, _):
            .recording(
                application: application,
                elapsed: elapsed,
                profile: profile,
                voiceControlVisible: true
            )
        case .possibleEnd(let application, let elapsed, _, _):
            .possibleEnd(
                application: application,
                elapsed: elapsed,
                profile: profile,
                voiceControlVisible: true
            )
        default:
            self
        }
    }
}
