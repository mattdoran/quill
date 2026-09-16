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
    NSTextFieldDelegate
{
    private enum SeparationState { case idle, separating(String), failed(String) }
    private struct Row {
        let voiceID: String
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
    private var separationState = SeparationState.idle
    private var lastSeparationTracks: Set<SourceTrack> = []
    private var lastSpeakerCounts: [SourceTrack: SpeakerCountSelection] = [:]
    private var player: AVAudioPlayer?
    private var stopTimer: Timer?
    private var nextSampleIndex: [String: Int] = [:]
    private weak var activePlayButton: NSButton?
    private var activeVoiceID: String?

    var sessionURL: URL { session }

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
        transcript = try TranscriptStore(session: session).read()
        self.isRecording = isRecording
        self.separateSpeakers = separateSpeakers
        self.chooseSpeakerCounts = chooseSpeakerCounts
        self.pasteboard = pasteboard
        self.profileStore = profileStore
        self.presence = presence
        for track in SourceTrack.allCases {
            let voices = transcript.voices.values.filter { $0.source == track.rawValue }
            if voices.contains(where: { $0.machine_label.hasPrefix("Voice ") }) {
                lastSpeakerCounts[track] = .exact(voices.count)
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
        paragraph.paragraphSpacing = 15
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let speaker: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let time: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for segment in transcript.segments {
            result.append(NSAttributedString(string: "\(Self.clock(segment.start_ms))  ", attributes: time))
            result.append(NSAttributedString(string: segment.speaker, attributes: speaker))
            if
                transcript.diarizer != nil,
                let voiceID = segment.voice_id,
                let voice = transcript.voices[voiceID]
            {
                result.append(NSAttributedString(
                    string: "   \(Self.sourceTag(for: voice))",
                    attributes: time
                ))
            }
            result.append(NSAttributedString(string: "\n\(segment.text)\n", attributes: body))
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
                    wrappingLabelWithString: "Providing the number of speakers gives the most reliable result."
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
        for id in transcript.voiceIDs {
            guard let voice = transcript.voices[id] else { continue }
            let row = makeRow(id: id, voice: voice, showSource: showSource)
            voiceStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: voiceStack.widthAnchor).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = voiceStack.arrangedSubviews.count > 3
        scroll.drawsBackground = false
        scroll.documentView = voiceStack
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
        voiceStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    private func makeRow(
        id: String,
        voice: TranscriptDocument.Voice,
        showSource: Bool
    ) -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 9
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        let voiceLabel = NSTextField(labelWithString: voice.machine_label)
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
        let context = Self.context(for: id, voice: voice, showSource: showSource)
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
        let sampleAvailable = voice.samples.first != nil && sourceURL(for: voice) != nil
        play.isEnabled = sampleAvailable
        play.title = sampleAvailable ? Self.initialPlayTitle(voice) : "Sample Unavailable"
        play.toolTip = sampleAvailable ? "Play a short sample" : "Source audio is unavailable"
        play.setAccessibilityLabel(
            sampleAvailable ? "Play sample for \(context)" : "Sample unavailable for \(context)"
        )
        var memoryButtons: [NSButton] = []
        if let suggestion = suggestions[id] {
            let use = ReviewButton(title: "Use \(suggestion.name)", target: self,
                               action: #selector(useSuggestionClicked(_:)))
            use.bezelStyle = .rounded
            use.controlSize = .small
            use.identifier = NSUserInterfaceItemIdentifier(id)
            use.toolTip = "Suggested from a remembered voice. Listen to a sample to check."
            memoryButtons.append(use)
        }
        if voice.embedding != nil, voice.embedding_model != nil {
            let remember = ReviewButton(title: "Remember Voice", target: self,
                                    action: #selector(rememberVoiceClicked(_:)))
            remember.bezelStyle = .rounded
            remember.controlSize = .small
            remember.identifier = NSUserInterfaceItemIdentifier(id)
            remember.toolTip = "Save this name and voice on this Mac for suggestions in future meetings."
            configureRememberButton(remember, voice: voice, name: field.stringValue, voiceID: id)
            memoryButtons.append(remember)
        }
        rows.append(Row(voiceID: id, field: field, playButton: play, memoryButtons: memoryButtons))
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
        // End the field editor's attachment before replacing its owning view.
        window?.makeFirstResponder(nil)
        let separating: Bool
        if case .separating = separationState { separating = true } else { separating = false }
        window?.standardWindowButton(.closeButton)?.isEnabled = !separating
        window?.contentView = buildContent()
        setInitialFocus()
        restoreFocus(focusedID)
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
        if window?.isVisible == true { refreshContent() }
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

    @objc private func playClicked(_ sender: NSButton) {
        guard !isRecording() else {
            let alert = NSAlert()
            alert.messageText = "Finish the recording first"
            alert.informativeText = "Playing a sample now would become part of the recording."
            _ = presence.runModal(alert)
            return
        }
        guard let id = sender.identifier?.rawValue, let voice = transcript.voices[id],
              !voice.samples.isEmpty, let source = sourceURL(for: voice) else { return }
        if activePlayButton === sender, player?.isPlaying == true { stopPlayback(); return }
        let index = nextSampleIndex[id, default: 0] % voice.samples.count
        let sample = voice.samples[index]
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
            sender.setAccessibilityLabel("Stop sample for \(Self.context(for: id, voice: voice))")
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
            try updated.applyVoiceNames(Dictionary(uniqueKeysWithValues: rows.map {
                ($0.voiceID, enteredName(in: $0))
            }))
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

    private func configureRememberButton(
        _ button: NSButton, voice: TranscriptDocument.Voice, name: String, voiceID: String
    ) {
        let remembered = profiles.contains { profile in
            profile.id == voice.remembered_profile_id && profile.name == normalized(name)
                && profile.contributions.contains {
                    $0.session_id == memorySessionID && $0.voice_id == voiceID
                        && $0.embedding.count == voice.embedding?.count
                }
        }
        button.title = remembered ? "Voice Remembered" : "Remember Voice"
        button.isEnabled = normalized(name) != nil && !remembered && profileError == nil
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let row = rows.first(where: { $0.field === field }),
              let voice = transcript.voices[row.voiceID] else { return }
        for button in row.memoryButtons where button.action == #selector(rememberVoiceClicked(_:)) {
            configureRememberButton(button, voice: voice, name: enteredName(in: row), voiceID: row.voiceID)
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
            if let voice = transcript.voices[id] {
                configureRememberButton(button, voice: voice, name: suggestion.name, voiceID: id)
            }
        }
    }

    @objc private func rememberVoiceClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, saveNames(refresh: false) else { return }
        do {
            let remembered = try profileStore.remember(
                document: transcript, sessionID: memorySessionID, voiceIDs: [id]
            )
            guard let profile = remembered[id] else { return }
            transcript.voices[id]?.remembered_profile_id = profile.id
            try TranscriptStore(session: session).write(transcript)
            refreshContent()
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
        let markdown = transcript.rendered(title: session.lastPathComponent)
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
            transcriptTextView?.textStorage?.setAttributedString(transcriptText())
        }
    }

    @objc private func openMarkdownClicked() {
        NSWorkspace.shared.open(SessionFiles.transcriptMarkdown(session))
    }

    @objc private func showFolderClicked() {
        NSWorkspace.shared.activateFileViewerSelecting([SessionFiles.transcriptMarkdown(session)])
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
        if let id = activeVoiceID, let voice = transcript.voices[id], let button = activePlayButton {
            let next = nextSampleIndex[id, default: 0] % max(voice.samples.count, 1)
            button.title = voice.samples.count > 1 ? "Next Sample \(next + 1) of \(voice.samples.count)" : "Replay Sample"
            button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            button.setAccessibilityLabel(
                voice.samples.count > 1
                    ? "Play sample \(next + 1) of \(voice.samples.count) for \(Self.context(for: id, voice: voice))"
                    : "Replay sample for \(Self.context(for: id, voice: voice))"
            )
        }
        activePlayButton = nil
        activeVoiceID = nil
    }

    private static func context(
        for id: String,
        voice: TranscriptDocument.Voice,
        showSource: Bool = true
    ) -> String {
        showSource
            ? "\(voice.machine_label) · \(sourceTag(for: voice))"
            : voice.machine_label
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

    private static func initialPlayTitle(_ voice: TranscriptDocument.Voice) -> String {
        voice.samples.count > 1 ? "Play Sample 1 of \(voice.samples.count)" : "Play Sample"
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
