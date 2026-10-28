import AppKit
import AVFAudio

private final class TranscriptReviewRootView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

private final class VoiceListStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Review advertises an explicit Tab path through samples and actions, even when
/// macOS's global keyboard-navigation preference is off.
private final class ReviewButton: NSButton {
    override var canBecomeKeyView: Bool {
        window != nil && isEnabled && !isHiddenOrHasHiddenAncestor
    }
}

@MainActor
final class VoiceReviewWindowController: NSWindowController, NSWindowDelegate,
    NSTextFieldDelegate, NSTextViewDelegate, AVAudioPlayerDelegate
{
    private enum SeparationState { case idle, separating(String), failed(String) }
    private struct Row {
        let voiceID: String
        let voiceIDs: [String]
        let field: NSTextField
        let playButton: NSButton
        let memoryButtons: [NSButton]
    }
    private struct FocusEntry {
        let id: String
        let view: NSView
    }

    private let session: URL
    private var transcript: TranscriptDocument
    private let isRecording: () -> Bool
    private let separateSpeakers: (
        [SourceTrack: SpeakerCountSelection],
        @escaping @Sendable (SpeakerSeparationProgress) -> Void
    ) async throws -> Void
    private let chooseSpeakerCounts: (([SourceTrack: SpeakerCountSelection]) -> [SourceTrack: SpeakerCountSelection]?)?
    private let pasteboard: NSPasteboard
    private let profileStore: VoiceProfileStore
    private var profiles: [VoiceProfile] = []
    private var suggestions: [String: VoiceProfileSuggestion] = [:]
    private var profileError: String?
    private let presence: ApplicationPresenceController
    private var rows: [Row] = []
    private var speakerActionButtons: [NSButton] = []
    private var focusEntries: [FocusEntry] = []
    private weak var transcriptTextView: NSTextView?
    private weak var speakerScrollView: NSScrollView?
    private var speakerScrollOrigin = NSPoint.zero
    private weak var separationDetail: NSTextField?
    private var separationState = SeparationState.idle
    private var lastSeparationTracks: Set<SourceTrack> = []
    private var lastSpeakerCounts: [SourceTrack: SpeakerCountSelection] = [:]
    private var player: AVAudioPlayer?
    private var stopTimer: Timer?
    private var nextSampleIndex: [String: Int] = [:]
    private weak var activePlayButton: NSButton?
    private var activeVoiceID: String?
    private var playingFrom: Int?

    var onClose: (() -> Void)?

    init(
        session: URL,
        isRecording: @escaping () -> Bool,
        separateSpeakers: @escaping (
            [SourceTrack: SpeakerCountSelection],
            @escaping @Sendable (SpeakerSeparationProgress) -> Void
        ) async throws -> Void,
        chooseSpeakerCounts: (([SourceTrack: SpeakerCountSelection]) -> [SourceTrack: SpeakerCountSelection]?)? = nil,
        pasteboard: NSPasteboard = .general,
        profileStore: VoiceProfileStore = VoiceProfileStore(),
        appearance: NSAppearance? = nil,
        presence: ApplicationPresenceController = ApplicationPresenceController()
    ) throws {
        self.session = session
        let document = try TranscriptStore(session: session).read()
        transcript = document
        self.isRecording = isRecording
        self.separateSpeakers = separateSpeakers
        self.chooseSpeakerCounts = chooseSpeakerCounts
        self.pasteboard = pasteboard
        self.profileStore = profileStore
        self.presence = presence
        for track in SourceTrack.allCases {
            let people = document.people.filter {
                document.voices[$0[0]]?.source == track.rawValue
            }
            if people.joined().contains(where: {
                document.voices[$0]?.machine_label.hasPrefix("Voice ") == true
            }) {
                lastSpeakerCounts[track] = .estimate(people.count)
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.title = "Transcript"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 760, height: 500)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = false
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.closeButton)?.isEnabled = true
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        setInitialFocus()
        window.center()
    }

    convenience init(
        session: URL,
        isRecording: @escaping () -> Bool,
        separateSpeakers: @escaping () async throws -> Void,
        appearance: NSAppearance? = nil,
        presence: ApplicationPresenceController = ApplicationPresenceController()
    ) throws {
        try self.init(
            session: session,
            isRecording: isRecording,
            separateSpeakers: { _, _ in try await separateSpeakers() },
            chooseSpeakerCounts: { $0.mapValues { _ in .automatic } },
            appearance: appearance,
            presence: presence
        )
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        if let window {
            presence.present(window)
        }
        if let initialFirstResponder = window?.initialFirstResponder {
            window?.makeFirstResponder(initialFirstResponder)
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopPlayback()
        onClose?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if case .separating = separationState { return false }
        guard hasUnsavedNames else { return true }
        let alert = NSAlert()
        alert.messageText = "Save speaker names?"
        alert.informativeText = "Your changes have not been saved to the transcript."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch presence.runModal(alert) {
        case .alertFirstButtonReturn:
            return saveNames(refresh: false)
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    private func buildContent() -> NSView {
        rows = []
        speakerActionButtons = []
        speakerScrollView = nil
        separationDetail = nil
        loadVoiceMemory()
        let root = TranscriptReviewRootView()
        let title = NSTextField(labelWithString: "Transcript")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let sessionLabel = NSTextField(labelWithString: SessionName.dated(session))
        sessionLabel.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, sessionLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        let markdown = ReviewButton(title: "Open Transcript File", target: self, action: #selector(openMarkdownClicked))
        markdown.bezelStyle = .rounded
        let finder = ReviewButton(title: "Show in Finder", target: self, action: #selector(showFolderClicked))
        finder.bezelStyle = .rounded
        let copy = ReviewButton(title: "Copy Markdown", target: self, action: #selector(copyMarkdownClicked(_:)))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = [.command, .shift]
        copy.toolTip = "Copy the entire transcript as Markdown, including current speaker names (⇧⌘C)"
        if case .separating = separationState { copy.isEnabled = false }
        let fileActions = NSStackView(views: [copy, finder, markdown])
        fileActions.orientation = .horizontal
        fileActions.spacing = 8

        let close = ReviewButton(title: "Close", target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        if case .separating = separationState { close.isEnabled = false }
        var reviewButtons = [close]
        if !transcript.voiceIDs.isEmpty {
            let save = ReviewButton(title: "Save Names", target: self, action: #selector(saveClicked))
            save.bezelStyle = .rounded
            save.keyEquivalent = "\r"
            if case .separating = separationState { save.isEnabled = false }
            reviewButtons.append(save)
        }
        let reviewActions = NSStackView(views: reviewButtons)
        reviewActions.orientation = .horizontal
        reviewActions.spacing = 8

        let transcriptScroll = makeTranscriptScrollView()
        let sidebar = makeSpeakerSidebar()
        let divider = NSBox()
        divider.boxType = .separator
        for view in [heading, transcriptScroll, divider, sidebar, fileActions, reviewActions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            transcriptScroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 22),
            transcriptScroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: fileActions.topAnchor, constant: -18),
            transcriptScroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -24),
            divider.topAnchor.constraint(equalTo: transcriptScroll.topAnchor),
            divider.bottomAnchor.constraint(equalTo: transcriptScroll.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            sidebar.topAnchor.constraint(equalTo: transcriptScroll.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 24),
            sidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: transcriptScroll.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 286),
            fileActions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            fileActions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            reviewActions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            reviewActions.bottomAnchor.constraint(equalTo: fileActions.bottomAnchor),
        ])
        focusEntries = [transcriptTextView].compactMap { view in
            view.map { FocusEntry(id: "transcript", view: $0) }
        }
        focusEntries += rows.flatMap { row in
            [
                FocusEntry(id: "name:\(row.voiceID)", view: row.field),
                FocusEntry(id: "play:\(row.voiceID)", view: row.playButton),
            ] + row.memoryButtons.enumerated().map {
                FocusEntry(id: "memory:\(row.voiceID):\($0.offset)", view: $0.element)
            }
        }
        focusEntries += speakerActionButtons.enumerated().map {
            FocusEntry(id: "speaker-action:\($0.offset)", view: $0.element)
        }
        focusEntries += [
            FocusEntry(id: "copy-markdown", view: copy),
            FocusEntry(id: "show-in-finder", view: finder),
            FocusEntry(id: "open-transcript", view: markdown),
        ]
        focusEntries += reviewButtons.map {
            FocusEntry(id: "review-action:\($0.title)", view: $0)
        }
        configureKeyViewLoop()
        configureNameFieldHelp()
        return root
    }

    private func makeTranscriptScrollView() -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = self
        // The default link look turns every turn's time blue and underlined.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.textStorage?.setAttributedString(transcriptText())
        textView.setAccessibilityLabel("Transcript text")
        transcriptTextView = textView
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        return scroll
    }

    private func transcriptText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8
        let lastParagraph = NSMutableParagraphStyle()
        lastParagraph.setParagraphStyle(paragraph)
        lastParagraph.paragraphSpacing = 15
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
        ]
        let speaker: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let time: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let meetingAudio = meetingAudioURL
        let recorded = TranscriptStore(session: session).recordedMilliseconds
            ?? transcript.segments.map(\.end_ms).max() ?? 0
        for turn in transcript.turns {
            result.append(NSAttributedString(string: turn.speaker, attributes: speaker))
            var clock = time
            if meetingAudio != nil {
                clock[.link] = Self.playLink(turn.startMilliseconds)
                clock[.toolTip] = "Play the meeting from here"
                if turn.startMilliseconds == playingFrom {
                    clock[.backgroundColor] = Self.playingHighlight
                }
            }
            result.append(NSAttributedString(string: "  ", attributes: time))
            result.append(NSAttributedString(
                string: TranscriptDocument.clock(
                    turn.startMilliseconds, longForm: recorded >= 3_600_000
                ),
                attributes: clock
            ))
            if
                transcript.diarizer != nil,
                let voiceID = turn.voiceID,
                let voice = transcript.voices[voiceID]
            {
                result.append(NSAttributedString(
                    string: "   \(Self.sourceTag(for: voice))",
                    attributes: time
                ))
            }
            result.append(NSAttributedString(string: "\n", attributes: time))
            for (index, parts) in turn.paragraphs.enumerated() {
                let style = index == turn.paragraphs.count - 1 ? lastParagraph : paragraph
                let line = body.merging([.paragraphStyle: style]) { $1 }
                for (position, part) in parts.enumerated() {
                    if position > 0 { result.append(NSAttributedString(string: " ", attributes: line)) }
                    switch part {
                    case .speech(let text):
                        result.append(NSAttributedString(string: text, attributes: line))
                    case .guess(let text):
                        result.append(NSAttributedString(string: text, attributes: line.merging([
                            .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                            .underlineColor: NSColor.tertiaryLabelColor,
                            .toolTip: "Unassigned: Quill joined this to \(turn.speaker)",
                        ]) { $1 }))
                    case .replies(let who, let text):
                        result.append(NSAttributedString(string: "[\(who): \(text)]", attributes: line.merging([
                            .foregroundColor: NSColor.secondaryLabelColor,
                        ]) { $1 }))
                    }
                }
                result.append(NSAttributedString(string: "\n", attributes: line))
            }
        }
        if result.length == 0 {
            result.append(NSAttributedString(
                string: "No spoken text was found in this recording.",
                attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        return result
    }

    private func makeSpeakerSidebar() -> NSView {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Speakers")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let keyboardHint = NSTextField(
            wrappingLabelWithString: "Return moves to the next name and saves from the last."
        )
        keyboardHint.font = .systemFont(ofSize: 11)
        keyboardHint.textColor = .secondaryLabelColor
        keyboardHint.isHidden = transcript.voiceIDs.isEmpty
        let header = NSStackView(views: [heading, keyboardHint])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        let content: NSView
        if case .idle = separationState {
            content = transcript.diarizer == nil ? makeBaselineReview() : makeSeparatedReview()
        } else {
            content = makeSeparationPrompt()
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        return root
    }

    private func makeBaselineReview() -> NSView {
        guard case .idle = separationState else { return makeSeparationPrompt() }
        let voices = makeVoiceList(showSource: false, minimumHeight: 230)
        let prompt = makeSeparationPrompt()
        let stack = NSStackView(views: [voices, prompt])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        voices.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        prompt.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeSeparatedReview() -> NSView {
        let voices = makeVoiceList(showSource: true, minimumHeight: 110)
        let action = makeSeparationPrompt()
        if TranscriptStore(session: session).canRestoreBeforeSpeakerSeparation,
           let actions = action as? NSStackView {
            let restore = ReviewButton(
                title: "Undo Voice Separation", target: self,
                action: #selector(restoreSeparationClicked)
            )
            restore.bezelStyle = .rounded
            speakerActionButtons.append(restore)
            actions.addArrangedSubview(restore)
        }
        let stack = NSStackView(views: [voices, action])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        voices.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        action.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeSeparationPrompt() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        switch separationState {
        case .idle:
            if sourceAudioAvailable {
                let heading = NSTextField(labelWithString: "Separate distinct voices")
                heading.font = .systemFont(ofSize: 12, weight: .semibold)
                heading.textColor = .secondaryLabelColor
                let limitation = NSTextField(
                    wrappingLabelWithString: "An estimate of how many people spoke gives the most reliable result."
                )
                limitation.font = .systemFont(ofSize: 11)
                limitation.textColor = .tertiaryLabelColor
                let explanation = NSStackView(views: [heading, limitation])
                explanation.orientation = .vertical
                explanation.alignment = .leading
                explanation.spacing = 3
                stack.addArrangedSubview(explanation)
            } else {
                let unavailable = NSTextField(
                    wrappingLabelWithString: "Source audio is no longer available, so voices cannot be separated."
                )
                unavailable.font = .systemFont(ofSize: 12, weight: .semibold)
                unavailable.textColor = .secondaryLabelColor
                stack.addArrangedSubview(unavailable)
            }
            let availableTracks = Set(SourceTrack.allCases.filter(sourceAvailable))
            if !availableTracks.isEmpty {
                stack.addArrangedSubview(separationButton(
                    title: separationTitle(), tracks: availableTracks
                ))
            }
            if !profiles.isEmpty {
                let forget = ReviewButton(title: "Forget Remembered Voices…", target: self,
                                      action: #selector(forgetVoicesClicked))
                forget.bezelStyle = .rounded
                speakerActionButtons.append(forget)
                stack.addArrangedSubview(forget)
            }
            if let profileError {
                let error = NSTextField(wrappingLabelWithString: "Voice memory unavailable: \(profileError)")
                error.font = .systemFont(ofSize: 11)
                error.textColor = .secondaryLabelColor
                stack.addArrangedSubview(error)
            }
        case .separating(let detailText):
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let status = NSTextField(labelWithString: "Separating speakers…")
            status.font = .systemFont(ofSize: 13, weight: .semibold)
            let row = NSStackView(views: [spinner, status])
            row.spacing = 8
            row.alignment = .centerY
            let detail = NSTextField(wrappingLabelWithString: detailText)
            separationDetail = detail
            detail.textColor = .secondaryLabelColor
            stack.addArrangedSubview(row)
            stack.addArrangedSubview(detail)
        case .failed(let message):
            let status = NSTextField(labelWithString: "Couldn’t separate speakers")
            status.font = .systemFont(ofSize: 13, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString: "The transcript is unchanged.\n\(message)")
            detail.textColor = .secondaryLabelColor
            let retry = separationButton(title: "Retry", tracks: lastSeparationTracks)
            stack.addArrangedSubview(status)
            stack.addArrangedSubview(detail)
            stack.addArrangedSubview(retry)
        }
        return stack
    }

    private func separationButton(title: String, tracks: Set<SourceTrack>) -> NSButton {
        let button = ReviewButton(title: title, target: self, action: #selector(separateClicked(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(
            tracks.map(\.rawValue).sorted().joined(separator: ",")
        )
        speakerActionButtons.append(button)
        return button
    }

    private func makeVoiceList(
        showSource: Bool,
        minimumHeight: CGFloat = 250
    ) -> NSView {
        let voiceStack = VoiceListStackView()
        voiceStack.orientation = .vertical
        voiceStack.alignment = .leading
        voiceStack.spacing = 10
        voiceStack.translatesAutoresizingMaskIntoConstraints = false
        for ids in transcript.people {
            guard let voice = transcript.voices[ids[0]] else { continue }
            let row = makeRow(ids: ids, voice: voice, showSource: showSource)
            voiceStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: voiceStack.widthAnchor).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = voiceStack.arrangedSubviews.count > 3
        scroll.drawsBackground = false
        scroll.documentView = voiceStack
        speakerScrollView = scroll
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
        voiceStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    private func makeRow(
        ids: [String],
        voice: TranscriptDocument.Voice,
        showSource: Bool
    ) -> NSView {
        let id = ids[0]
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 9
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        let voiceLabel = NSTextField(labelWithString: machineLabel(for: ids))
        voiceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        var headerViews: [NSView] = [voiceLabel]
        if showSource {
            let sourceLabel = NSTextField(labelWithString: Self.sourceTag(for: voice))
            sourceLabel.font = .systemFont(ofSize: 11)
            sourceLabel.textColor = .secondaryLabelColor
            headerViews.append(sourceLabel)
        }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 7
        let context = context(for: ids, showSource: showSource)
        let field = NSTextField(string: voice.name ?? "")
        field.placeholderString = "Name this voice"
        field.setAccessibilityLabel("Name for \(context)")
        field.delegate = self
        let play = ReviewButton(title: "Play Sample", target: self, action: #selector(playClicked(_:)))
        play.bezelStyle = .rounded
        play.controlSize = .small
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        play.imagePosition = .imageLeading
        play.identifier = NSUserInterfaceItemIdentifier(id)
        let sampleCount = samples(for: ids).count
        let sampleAvailable = sampleCount > 0
        play.isEnabled = sampleAvailable
        play.title = sampleAvailable ? Self.initialPlayTitle(sampleCount) : "Sample Unavailable"
        play.toolTip = sampleAvailable ? "Play a short sample" : "Source audio is unavailable"
        play.setAccessibilityLabel(
            sampleAvailable ? "Play sample for \(context)" : "Sample unavailable for \(context)"
        )
        var memoryButtons: [NSButton] = []
        if ids.count == 1, let suggestion = suggestions[id] {
            let use = ReviewButton(title: "Use \(suggestion.name)", target: self,
                               action: #selector(useSuggestionClicked(_:)))
            use.bezelStyle = .rounded
            use.controlSize = .small
            use.identifier = NSUserInterfaceItemIdentifier(id)
            use.toolTip = "Suggested from a remembered voice. Listen to a sample to check."
            memoryButtons.append(use)
        }
        if ids.contains(where: {
            transcript.voices[$0]?.embedding != nil && transcript.voices[$0]?.embedding_model != nil
        }) {
            let remember = ReviewButton(title: "Remember Voice", target: self,
                                    action: #selector(rememberVoiceClicked(_:)))
            remember.bezelStyle = .rounded
            remember.controlSize = .small
            remember.identifier = NSUserInterfaceItemIdentifier(id)
            remember.toolTip = "Save this name and voice on this Mac for suggestions in future meetings."
            configureRememberButton(remember, voiceIDs: ids, name: field.stringValue)
            memoryButtons.append(remember)
        }
        if ids.count > 1 {
            let separate = ReviewButton(title: "Not the Same Person", target: self,
                                    action: #selector(notSamePersonClicked(_:)))
            separate.bezelStyle = .rounded
            separate.controlSize = .small
            separate.identifier = NSUserInterfaceItemIdentifier(id)
            separate.toolTip = "Show these voices separately. The voice with the most speech keeps the name."
            memoryButtons.append(separate)
        }
        rows.append(Row(
            voiceID: id, voiceIDs: ids, field: field, playButton: play, memoryButtons: memoryButtons
        ))
        let stack = NSStackView(views: [header, field, play] + memoryButtons)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -11),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return card
    }

    private var sourceAudioAvailable: Bool {
        transcript.voices.values.contains { sourceURL(for: $0) != nil }
    }

    private func sourceAvailable(for track: SourceTrack) -> Bool {
        transcript.voices.values.contains {
            $0.source == track.rawValue && sourceURL(for: $0) != nil
        }
    }

    private func refreshContent() {
        let focusedID = currentFocusID()
        let transcriptOrigin = transcriptTextView?.enclosingScrollView?.contentView.bounds.origin
        let selectedRanges = transcriptTextView?.selectedRanges
        let previousText = transcriptTextView?.string
        if let speakerScrollView {
            speakerScrollOrigin = speakerScrollView.contentView.bounds.origin
        }
        // End the field editor's attachment before replacing its owning view.
        window?.makeFirstResponder(nil)
        let separating: Bool
        if case .separating = separationState { separating = true } else { separating = false }
        window?.standardWindowButton(.closeButton)?.isEnabled = !separating
        window?.contentView = buildContent()
        setInitialFocus()
        restoreFocus(focusedID)
        if previousText == transcriptTextView?.string, let selectedRanges {
            transcriptTextView?.selectedRanges = selectedRanges
        }
        restoreScrollPositions(transcriptOrigin: transcriptOrigin)
    }

    private func restoreScrollPositions(transcriptOrigin: NSPoint?) {
        window?.contentView?.layoutSubtreeIfNeeded()
        if let textView = transcriptTextView, let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
            textView.sizeToFit()
        }
        for (scroll, origin) in [
            (transcriptTextView?.enclosingScrollView, transcriptOrigin),
            (speakerScrollView, Optional(speakerScrollOrigin)),
        ] {
            guard let scroll, let origin else { continue }
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func configureKeyViewLoop() {
        guard !focusEntries.isEmpty else { return }
        for index in focusEntries.indices {
            focusEntries[index].view.nextKeyView = focusEntries[(index + 1) % focusEntries.count].view
        }
    }

    private func configureNameFieldHelp() {
        for (index, row) in rows.enumerated() {
            row.field.setAccessibilityHelp(
                index + 1 < rows.count
                    ? "Press Return to move to the next speaker name."
                    : "Press Return to save speaker names."
            )
        }
    }

    private func setInitialFocus() {
        window?.initialFirstResponder = rows.first?.field ?? transcriptTextView
    }

    private func currentFocusID() -> String? {
        guard let responder = window?.firstResponder else { return nil }
        return focusEntries.first { entry in
            responder === entry.view
                || (entry.view as? NSTextField)?.currentEditor() === responder
        }?.id
    }

    private func restoreFocus(_ id: String?) {
        guard
            window?.isVisible == true,
            let id,
            let view = focusEntries.first(where: { $0.id == id })?.view
        else { return }
        window?.makeFirstResponder(view)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard
            commandSelector == #selector(NSResponder.insertNewline(_:)),
            let field = control as? NSTextField,
            let index = rows.firstIndex(where: { $0.field === field })
        else { return false }

        if index + 1 < rows.count {
            window?.makeFirstResponder(rows[index + 1].field)
        } else {
            _ = saveNames()
        }
        return true
    }

    @objc private func separateClicked(_ sender: NSButton) {
        let tracks = Set(
            (sender.identifier?.rawValue ?? "")
                .split(separator: ",")
                .compactMap { SourceTrack(rawValue: String($0)) }
        )
        guard !tracks.isEmpty else { return }
        if isRecording() {
            let alert = NSAlert()
            alert.messageText = "Finish the recording first"
            alert.informativeText = "Speaker analysis will be available when the current recording ends."
            _ = presence.runModal(alert)
            return
        }
        if hasUnsavedNames, !saveNames(refresh: false) { return }
        let previous = lastSpeakerCounts.filter { tracks.contains($0.key) }
        let selections: [SourceTrack: SpeakerCountSelection]?
        if let chooseSpeakerCounts {
            selections = chooseSpeakerCounts(previous)
        } else {
            selections = promptForSpeakerCounts(tracks: tracks, previous: previous)
        }
        guard let selections, !selections.isEmpty, Set(selections.keys).isSubset(of: tracks) else {
            return
        }
        lastSeparationTracks = Set(selections.keys)
        lastSpeakerCounts = lastSpeakerCounts.filter { !tracks.contains($0.key) }
        lastSpeakerCounts.merge(selections) { _, new in new }
        separationState = .separating("Preparing the speaker model…")
        refreshContent()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await separateSpeakers(selections) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateSeparationProgress(progress)
                    }
                }
                transcript = try TranscriptStore(session: session).read()
                separationState = .idle
                refreshContent()
            } catch {
                separationState = .failed(error.localizedDescription)
                if window?.isVisible == true { refreshContent() }
            }
        }
    }

    private func updateSeparationProgress(_ progress: SpeakerSeparationProgress) {
        guard case .separating = separationState else { return }
        switch progress.stage {
        case .preparingModel:
            separationState = .separating("Preparing the speaker model…")
        case .analysing(let source, let completed, let total):
            let name = source == .microphone ? "local" : "remote"
            let percent = total > 0 ? Int((Double(completed) / Double(total)) * 100) : 0
            let detail = "Analysing \(name) audio: \(percent)%."
            if case .separating(let current) = separationState, current == detail { return }
            separationState = .separating(detail)
        case .clustering(let source):
            let name = source == .microphone ? "local" : "remote"
            separationState = .separating(
                "Finishing analysis and clustering voices in \(name) audio…"
            )
        case .updatingTranscript:
            separationState = .separating("Updating the transcript…")
        }
        if case .separating(let detail) = separationState {
            separationDetail?.stringValue = detail
        }
    }

    private func separationTitle() -> String {
        let separated = transcript.voices.values.contains {
            $0.machine_label.hasPrefix("Voice ")
        }
        return separated ? "Separate Voices Again…" : "Separate Voices…"
    }

    private func promptForSpeakerCounts(
        tracks: Set<SourceTrack>,
        previous: [SourceTrack: SpeakerCountSelection]
    ) -> [SourceTrack: SpeakerCountSelection]? {
        let (alert, choices) = SpeakerCountPicker.makeAlert(
            tracks: tracks,
            selections: previous,
            replacingSeparatedTracks: transcript.diarizer != nil
        )
        guard presence.runModal(alert) == .alertFirstButtonReturn else { return nil }
        return choices.selections
    }

    @objc private func restoreSeparationClicked() {
        guard !isRecording() else { return }
        let alert = NSAlert()
        alert.messageText = "Undo voice separation?"
        alert.informativeText = "This restores the original Me and Them transcript and removes separated voice names."
        alert.addButton(withTitle: "Undo Separation")
        alert.addButton(withTitle: "Cancel")
        guard presence.runModal(alert) == .alertFirstButtonReturn else { return }
        do {
            try TranscriptStore(session: session).restoreBeforeSpeakerSeparation()
            transcript = try TranscriptStore(session: session).read()
            lastSeparationTracks = []
            lastSpeakerCounts = [:]
            separationState = .idle
            refreshContent()
        } catch {
            _ = presence.runModal(NSAlert(error: error))
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard
            let url = link as? URL, url.scheme == Self.playScheme,
            let start = Int(url.absoluteString.dropFirst(Self.playScheme.count + 1))
        else { return false }
        playMeeting(from: start)
        return true
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.stopPlayback()
        }
    }

    private func playMeeting(from start: Int) {
        guard allowPlayback(what: "Playing the meeting") else { return }
        if playingFrom == start, player?.isPlaying == true { stopPlayback(); return }
        guard let audio = meetingAudioURL else { return }
        do {
            stopPlayback()
            let player = try AVAudioPlayer(contentsOf: audio)
            player.delegate = self
            player.currentTime = TimeInterval(start) / 1000
            player.prepareToPlay()
            player.play()
            self.player = player
            playingFrom = start
            if let storage = transcriptTextView?.textStorage {
                storage.enumerateAttribute(
                    .link, in: NSRange(location: 0, length: storage.length)
                ) { value, range, stop in
                    guard (value as? URL) == Self.playLink(start) else { return }
                    storage.addAttribute(.backgroundColor, value: Self.playingHighlight, range: range)
                    stop.pointee = true
                }
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Meeting audio could not be played"
            _ = presence.runModal(alert)
        }
    }

    private func allowPlayback(what: String) -> Bool {
        guard isRecording() else { return true }
        let alert = NSAlert()
        alert.messageText = "Finish the recording first"
        alert.informativeText = "\(what) now would become part of the recording."
        _ = presence.runModal(alert)
        return false
    }

    @objc private func playClicked(_ sender: NSButton) {
        guard allowPlayback(what: "Playing a sample") else { return }
        guard let id = sender.identifier?.rawValue,
              let row = rows.first(where: { $0.voiceID == id }) else { return }
        let samples = samples(for: row.voiceIDs)
        guard !samples.isEmpty else { return }
        if activePlayButton === sender, player?.isPlaying == true { stopPlayback(); return }
        let index = nextSampleIndex[id, default: 0] % samples.count
        let sample = samples[index].sample
        guard let voice = transcript.voices[samples[index].voiceID],
              let source = sourceURL(for: voice) else { return }
        nextSampleIndex[id] = index + 1
        do {
            stopPlayback()
            let player = try AVAudioPlayer(contentsOf: source)
            player.currentTime = TimeInterval(sample.start_ms) / 1000
            player.prepareToPlay()
            player.play()
            self.player = player
            activePlayButton = sender
            activeVoiceID = id
            sender.title = "Stop"
            sender.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
            sender.setAccessibilityLabel("Stop sample for \(context(for: row.voiceIDs))")
            let duration = max(0.5, min(8, TimeInterval(sample.end_ms - sample.start_ms) / 1000))
            stopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
                [weak self] _ in MainActor.assumeIsolated { self?.stopPlayback() }
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Sample could not be played"
            _ = presence.runModal(alert)
        }
    }

    @objc private func saveClicked() {
        _ = saveNames()
    }

    @objc private func closeClicked() {
        window?.performClose(nil)
    }

    private func saveNames(refresh: Bool = true) -> Bool {
        stopPlayback()
        do {
            var updated = transcript
            try updated.applyVoiceNames(Dictionary(uniqueKeysWithValues: rows.flatMap { row in
                row.voiceIDs.map { ($0, enteredName(in: row)) }
            }))
            var spelling: [String: String] = [:]
            for ids in updated.people where ids.count > 1 {
                guard let name = updated.voices[ids[0]]?.name else { continue }
                for id in ids.dropFirst() { spelling[id] = name }
            }
            try updated.applyVoiceNames(spelling)
            try TranscriptStore(session: session).write(updated)
            transcript = updated
            if refresh { refreshContent() }
            return true
        } catch {
            _ = presence.runModal(NSAlert(error: error))
            return false
        }
    }

    private var memorySessionID: String {
        let started = try? SessionMetadataStore.readManifest(session).started
        if let started, !started.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return started
        }
        return transcript.created_at
    }

    private func loadVoiceMemory() {
        do {
            profiles = try profileStore.load()
            suggestions = try profileStore.suggestions(for: transcript)
            profileError = nil
        } catch {
            profiles = []
            suggestions = [:]
            profileError = error.localizedDescription
        }
    }

    private func configureRememberButton(_ button: NSButton, voiceIDs: [String], name: String) {
        let remembered = voiceIDs.allSatisfy { voiceID in
            guard let voice = transcript.voices[voiceID], voice.embedding != nil else { return true }
            return profiles.contains { profile in
                profile.id == voice.remembered_profile_id && profile.name == normalized(name)
                    && profile.contributions.contains {
                        $0.session_id == memorySessionID && $0.voice_id == voiceID
                            && $0.embedding.count == voice.embedding?.count
                    }
            }
        }
        button.title = remembered ? "Voice Remembered" : "Remember Voice"
        button.isEnabled = normalized(name) != nil && !remembered && profileError == nil
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let row = rows.first(where: { $0.field === field }) else { return }
        for button in row.memoryButtons where button.action == #selector(rememberVoiceClicked(_:)) {
            configureRememberButton(button, voiceIDs: row.voiceIDs, name: enteredName(in: row))
        }
    }

    @objc private func useSuggestionClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let suggestion = suggestions[id],
              let row = rows.first(where: { $0.voiceID == id }) else { return }
        window?.makeFirstResponder(row.field)
        row.field.stringValue = suggestion.name
        row.field.currentEditor()?.string = suggestion.name
        transcript.voices[id]?.remembered_profile_id = suggestion.profileID
        for button in row.memoryButtons where button.action == #selector(rememberVoiceClicked(_:)) {
            configureRememberButton(button, voiceIDs: row.voiceIDs, name: suggestion.name)
        }
    }

    @objc private func rememberVoiceClicked(_ sender: NSButton) {
        guard
            let id = sender.identifier?.rawValue,
            let voiceIDs = rows.first(where: { $0.voiceID == id })?.voiceIDs,
            saveNames(refresh: false)
        else { return }
        do {
            // One person is one profile, so later voices join the first one's.
            var profileID = voiceIDs.lazy.compactMap { self.transcript.voices[$0]?.remembered_profile_id }.first
            for voiceID in voiceIDs {
                if let profileID { transcript.voices[voiceID]?.remembered_profile_id = profileID }
                guard let profile = try profileStore.remember(
                    document: transcript, sessionID: memorySessionID, voiceIDs: [voiceID]
                )[voiceID] else { continue }
                profileID = profile.id
                transcript.voices[voiceID]?.remembered_profile_id = profile.id
            }
            try TranscriptStore(session: session).write(transcript)
            refreshContent()
        } catch {
            _ = presence.runModal(NSAlert(error: error))
        }
    }

    @objc private func notSamePersonClicked(_ sender: NSButton) {
        guard
            let id = sender.identifier?.rawValue,
            let voiceIDs = rows.first(where: { $0.voiceID == id })?.voiceIDs,
            voiceIDs.count > 1,
            saveNames(refresh: false)
        else { return }
        let speech = transcript.segments.reduce(into: [String: Int]()) { speech, segment in
            guard let voiceID = segment.voice_id else { return }
            speech[voiceID, default: 0] += segment.end_ms - segment.start_ms
        }
        let kept = voiceIDs.reduce(voiceIDs[0]) {
            speech[$1, default: 0] > speech[$0, default: 0] ? $1 : $0
        }
        let separated = voiceIDs.filter { $0 != kept }
        do {
            var updated = transcript
            for voiceID in separated where updated.voices[voiceID]?.remembered_profile_id != nil {
                try profileStore.forgetContribution(sessionID: memorySessionID, voiceID: voiceID)
                updated.voices[voiceID]?.remembered_profile_id = nil
            }
            try updated.applyVoiceNames(Dictionary(uniqueKeysWithValues: separated.map { ($0, "") }))
            try TranscriptStore(session: session).write(updated)
            transcript = updated
            refreshContent()
            if let field = rows.first(where: { $0.voiceID == separated[0] })?.field {
                window?.makeFirstResponder(field)
            }
        } catch {
            _ = presence.runModal(NSAlert(error: error))
        }
    }

    @objc private func forgetVoicesClicked() {
        let alert = NSAlert()
        alert.messageText = "Forget all remembered voices?"
        alert.informativeText = "Future meetings will no longer suggest these names. Saved transcript names are kept."
        alert.addButton(withTitle: "Forget Voices")
        alert.addButton(withTitle: "Cancel")
        guard presence.runModal(alert) == .alertFirstButtonReturn else { return }
        do {
            try profileStore.forgetAll()
            for id in transcript.voiceIDs { transcript.voices[id]?.remembered_profile_id = nil }
            // Preserve pending field edits when rebuilding the sidebar.
            guard saveNames(refresh: false) else { return }
            refreshContent()
        } catch {
            _ = presence.runModal(NSAlert(error: error))
        }
    }

    @objc private func copyMarkdownClicked(_ sender: NSButton) {
        if hasUnsavedNames, !saveNames(refresh: false) { return }
        let markdown = TranscriptStore(session: session).markdown(for: transcript)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(markdown, forType: .string)
        item.setString(markdown, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
        if pasteboard.writeObjects([item]) {
            sender.title = "Copied!"
            Task { @MainActor [weak sender] in
                try? await Task.sleep(for: .seconds(2))
                sender?.title = "Copy Markdown"
            }
            let text = transcriptText()
            if let textView = transcriptTextView, textView.attributedString() != text {
                let origin = textView.enclosingScrollView?.contentView.bounds.origin
                let selectedRanges = textView.selectedRanges
                let sameText = textView.string == text.string
                textView.textStorage?.setAttributedString(text)
                if sameText { textView.selectedRanges = selectedRanges }
                if let speakerScrollView {
                    speakerScrollOrigin = speakerScrollView.contentView.bounds.origin
                }
                restoreScrollPositions(transcriptOrigin: origin)
            }
        }
    }

    @objc private func openMarkdownClicked() {
        NSWorkspace.shared.open(SessionFiles.transcriptMarkdown(session))
    }

    @objc private func showFolderClicked() {
        NSWorkspace.shared.activateFileViewerSelecting([SessionFiles.transcriptMarkdown(session)])
    }

    private var meetingAudioURL: URL? {
        guard let path = (try? SessionMetadataStore.readManifest(session))?.files.meeting else {
            return nil
        }
        let url = session.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static let playScheme = "quill-play"
    private static let playingHighlight = NSColor.controlAccentColor.withAlphaComponent(0.25)

    private static func playLink(_ start: Int) -> URL {
        URL(string: "\(playScheme):\(start)")!
    }

    private func sourceURL(for voice: TranscriptDocument.Voice) -> URL? {
        let url = session.appendingPathComponent(voice.audio_file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func stopPlayback() {
        stopTimer?.invalidate()
        stopTimer = nil
        player?.stop()
        player = nil
        if playingFrom != nil, let storage = transcriptTextView?.textStorage {
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        }
        playingFrom = nil
        if let id = activeVoiceID, let button = activePlayButton,
           let voiceIDs = rows.first(where: { $0.voiceID == id })?.voiceIDs {
            let count = samples(for: voiceIDs).count
            let next = nextSampleIndex[id, default: 0] % max(count, 1)
            button.title = count > 1 ? "Next Sample \(next + 1) of \(count)" : "Replay Sample"
            button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            button.setAccessibilityLabel(
                count > 1
                    ? "Play sample \(next + 1) of \(count) for \(context(for: voiceIDs))"
                    : "Replay sample for \(context(for: voiceIDs))"
            )
        }
        activePlayButton = nil
        activeVoiceID = nil
    }

    /// Alternates between a person's voices, so the first samples cover each.
    private func samples(
        for voiceIDs: [String]
    ) -> [(voiceID: String, sample: TranscriptDocument.Voice.Sample)] {
        let lists = voiceIDs.map { id -> [(voiceID: String, sample: TranscriptDocument.Voice.Sample)] in
            guard let voice = transcript.voices[id], sourceURL(for: voice) != nil else { return [] }
            return voice.samples.map { (id, $0) }
        }
        let longest = lists.map(\.count).max() ?? 0
        return (0..<longest).flatMap { index in lists.compactMap { index < $0.count ? $0[index] : nil } }
    }

    private func machineLabel(for voiceIDs: [String]) -> String {
        let labels = voiceIDs.compactMap { transcript.voices[$0]?.machine_label }
        guard labels.count > 1 else { return labels.first ?? "" }
        let numbers = labels.compactMap { $0.hasPrefix("Voice ") ? String($0.dropFirst("Voice ".count)) : nil }
        guard numbers.count == labels.count else { return ListFormatter.localizedString(byJoining: labels) }
        return "Voices " + ListFormatter.localizedString(byJoining: numbers)
    }

    private func context(for voiceIDs: [String], showSource: Bool = true) -> String {
        let label = machineLabel(for: voiceIDs)
        guard showSource, let voice = voiceIDs.first.flatMap({ transcript.voices[$0] }) else { return label }
        return "\(label) · \(Self.sourceTag(for: voice))"
    }

    private static func sourceTag(for voice: TranscriptDocument.Voice) -> String {
        voice.source == "mic" ? "local" : "remote"
    }

    private var hasUnsavedNames: Bool {
        rows.contains { row in
            normalized(enteredName(in: row)) != normalized(transcript.voices[row.voiceID]?.name ?? "")
        }
    }

    private func enteredName(in row: Row) -> String {
        row.field.currentEditor()?.string ?? row.field.stringValue
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func initialPlayTitle(_ sampleCount: Int) -> String {
        sampleCount > 1 ? "Play Sample 1 of \(sampleCount)" : "Play Sample"
    }
}
