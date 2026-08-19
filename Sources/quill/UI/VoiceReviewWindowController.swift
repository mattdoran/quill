import AppKit
import AVFAudio

private final class VoiceReviewStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class VoiceReviewRootView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

@MainActor
final class VoiceReviewWindowController: NSWindowController, NSWindowDelegate {
    private enum SeparationState {
        case idle
        case separating
        case failed(String)
    }

    private struct Row {
        let voiceID: String
        let field: NSTextField
    }

    private let session: URL
    private var transcript: TranscriptDocument
    private let isRecording: () -> Bool
    private let separateSpeakers: () async throws -> Void
    private var rows: [Row] = []
    private var separationState = SeparationState.idle
    private var player: AVAudioPlayer?
    private var stopTimer: Timer?
    private var nextSampleIndex: [String: Int] = [:]
    private weak var activePlayButton: NSButton?
    private var activeVoiceID: String?

    var sessionURL: URL { session }

    init(
        session: URL,
        isRecording: @escaping () -> Bool,
        separateSpeakers: @escaping () async throws -> Void,
        appearance: NSAppearance? = nil
    ) throws {
        self.session = session
        self.transcript = try TranscriptStore(session: session).read()
        self.isRecording = isRecording
        self.separateSpeakers = separateSpeakers

        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: 540,
                height: transcript.diarizer == nil ? 230 : 540
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.title = "Review Speakers"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        rows.first?.field.window?.makeFirstResponder(rows.first?.field)
    }

    func windowWillClose(_ notification: Notification) { stopPlayback() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if case .separating = separationState { return false }
        return true
    }

    private func buildContent() -> NSView {
        rows = []
        guard transcript.diarizer != nil else { return buildSeparationContent() }
        let root = VoiceReviewRootView()

        let title = NSTextField(labelWithString: transcript.unidentifiedVoiceIDs.isEmpty
            ? "Edit voice names"
            : "Who is speaking?")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let detail = NSTextField(
            wrappingLabelWithString: "\(SessionName.dated(session))\nPlay a sample, then add the name you want in the transcript."
        )
        detail.textColor = .secondaryLabelColor

        let voiceStack = VoiceReviewStackView()
        voiceStack.orientation = .vertical
        voiceStack.spacing = 10
        voiceStack.alignment = .leading
        voiceStack.translatesAutoresizingMaskIntoConstraints = false

        for id in transcript.voiceIDs {
            guard let voice = transcript.voices[id] else { continue }
            voiceStack.addArrangedSubview(makeRow(id: id, voice: voice))
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = voiceStack.arrangedSubviews.count > 4
        scroll.drawsBackground = false
        scroll.documentView = voiceStack
        scroll.contentView.scroll(to: .zero)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save Names", target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded

        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        for view in [title, detail, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -20),
            voiceStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
        ])
        return root
    }

    private func buildSeparationContent() -> NSView {
        let root = VoiceReviewRootView()
        let title = NSTextField(labelWithString: "Review Speakers")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let sessionLabel = NSTextField(labelWithString: SessionName.dated(session))
        sessionLabel.textColor = .secondaryLabelColor

        let status: NSTextField
        let detail: NSTextField
        let primary: NSButton?
        switch separationState {
        case .idle:
            status = NSTextField(labelWithString: "Separate individual speakers?")
            detail = NSTextField(wrappingLabelWithString: sourceAudioAvailable
                ? "Quill currently groups everyone in the room together and everyone on the call together."
                : "Source audio is no longer available, so this transcript cannot be reprocessed."
            )
            let button = NSButton(
                title: "Separate Speakers",
                target: self,
                action: #selector(separateClicked)
            )
            button.bezelStyle = .rounded
            button.keyEquivalent = "\r"
            button.isEnabled = sourceAudioAvailable
            button.toolTip = sourceAudioAvailable ? nil
                : "Source audio is no longer available"
            primary = button
        case .separating:
            status = NSTextField(labelWithString: "Separating speakers…")
            detail = NSTextField(wrappingLabelWithString:
                "This may take a few minutes. Keep this window open while Quill analyses the recording."
            )
            primary = nil
        case .failed(let message):
            status = NSTextField(labelWithString: "Couldn’t separate speakers")
            detail = NSTextField(wrappingLabelWithString:
                "Your existing transcript is unchanged.\n\(message)"
            )
            let button = NSButton(title: "Retry", target: self, action: #selector(separateClicked))
            button.bezelStyle = .rounded
            primary = button
        }
        status.font = .systemFont(ofSize: 15, weight: .semibold)
        detail.textColor = .secondaryLabelColor

        let close = NSButton(title: "Close", target: self, action: #selector(cancelClicked))
        close.keyEquivalent = "\u{1b}"
        if case .separating = separationState { close.isEnabled = false }
        let buttons = NSStackView(views: [close] + (primary.map { [$0] } ?? []))
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let statusRow: NSStackView
        if case .separating = separationState {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            statusRow = NSStackView(views: [spinner, status])
            statusRow.spacing = 8
            statusRow.alignment = .centerY
        } else {
            statusRow = NSStackView(views: [status])
        }
        let content = NSStackView(views: [statusRow, detail])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8

        for view in [title, sessionLabel, content, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            sessionLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            sessionLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            content.topAnchor.constraint(equalTo: sessionLabel.bottomAnchor, constant: 22),
            content.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            buttons.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
        ])
        return root
    }

    private var sourceAudioAvailable: Bool {
        !transcript.voices.isEmpty && transcript.voices.values.allSatisfy {
            sourceURL(for: $0) != nil
        }
    }

    private func refreshContent() {
        let isSeparating: Bool
        if case .separating = separationState { isSeparating = true } else { isSeparating = false }
        window?.standardWindowButton(.closeButton)?.isEnabled = !isSeparating
        window?.setContentSize(NSSize(
            width: 540,
            height: transcript.diarizer == nil ? 230 : 540
        ))
        window?.contentView = buildContent()
    }

    @objc private func separateClicked() {
        guard sourceAudioAvailable else { return }
        if isRecording() {
            let alert = NSAlert()
            alert.messageText = "Finish the recording first"
            alert.informativeText =
                "Speaker analysis will be available when the current recording ends."
            alert.runModal()
            return
        }

        separationState = .separating
        refreshContent()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await separateSpeakers()
                transcript = try TranscriptStore(session: session).read()
                separationState = .idle
                refreshContent()
                rows.first?.field.window?.makeFirstResponder(rows.first?.field)
            } catch {
                separationState = .failed(error.localizedDescription)
                if window?.isVisible == true { refreshContent() }
            }
        }
    }

    private func makeRow(id: String, voice: TranscriptDocument.Voice) -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 10
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = voice.source == "mic" ? .systemIndigo : .systemGreen
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.setAccessibilityElement(false)

        let context = NSTextField(labelWithString: Self.context(for: id, voice: voice))
        context.font = .systemFont(ofSize: 11, weight: .medium)
        context.textColor = .secondaryLabelColor

        let field = NSTextField(string: voice.name ?? "")
        field.placeholderString = "Name this voice"
        field.font = .systemFont(ofSize: 15)
        field.setAccessibilityLabel("Name for \(context.stringValue)")
        rows.append(Row(voiceID: id, field: field))

        let play = NSButton(
            title: "Play Sample",
            target: self,
            action: #selector(playClicked(_:))
        )
        play.bezelStyle = .rounded
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        play.imagePosition = .imageLeading
        play.identifier = NSUserInterfaceItemIdentifier(id)
        let sampleAvailable = voice.samples.first != nil && sourceURL(for: voice) != nil
        play.isEnabled = sampleAvailable
        play.title = sampleAvailable ? Self.initialPlayTitle(voice) : "Sample Unavailable"
        play.toolTip = sampleAvailable ? "Play a short sample of this voice" : "Source audio is unavailable"
        play.setAccessibilityLabel("Play sample for \(context.stringValue)")

        let textStack = NSStackView(views: [context, field])
        textStack.orientation = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let row = NSStackView(views: [icon, textStack, play])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 76),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 235),
        ])
        return card
    }

    @objc private func playClicked(_ sender: NSButton) {
        guard !isRecording() else {
            let alert = NSAlert()
            alert.messageText = "Finish the recording first"
            alert.informativeText = "Playing a sample now would become part of the recording."
            alert.runModal()
            return
        }
        guard
            let id = sender.identifier?.rawValue,
            let voice = transcript.voices[id],
            !voice.samples.isEmpty,
            let source = sourceURL(for: voice)
        else { return }

        if activePlayButton === sender, player?.isPlaying == true {
            stopPlayback()
            return
        }

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
            alert.runModal()
        }
    }

    @objc private func saveClicked() {
        stopPlayback()
        do {
            try transcript.applyVoiceNames(Dictionary(uniqueKeysWithValues: rows.map {
                ($0.voiceID, $0.field.stringValue)
            }))
            try TranscriptStore(session: session).write(transcript)
            close()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func cancelClicked() {
        stopPlayback()
        close()
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
        if
            let id = activeVoiceID,
            let voice = transcript.voices[id],
            let button = activePlayButton
        {
            let next = nextSampleIndex[id, default: 0] % max(voice.samples.count, 1)
            button.title = voice.samples.count > 1
                ? "Next Sample \(next + 1) of \(voice.samples.count)"
                : "Replay Sample"
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

    private static func context(for id: String, voice: TranscriptDocument.Voice) -> String {
        let number = id.split(separator: ":").last.map(String.init) ?? ""
        let place = voice.source == "mic" ? "In the room" : "On the call"
        return "\(place) · Voice \(number)"
    }

    private static func initialPlayTitle(_ voice: TranscriptDocument.Voice) -> String {
        voice.samples.count > 1 ? "Play Sample 1 of \(voice.samples.count)" : "Play Sample"
    }
}
