import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    var recordingsPath: (() -> String)?
    var onChangeRecordingsFolder: (() -> Void)?
    var onRetentionChanged: (() -> Void)?
    var onDownloadModels: (() -> Void)?
    var onRemoveModels: (() -> Void)?

    private let pathLabel = NSTextField(labelWithString: "")
    private let retention = NSPopUpButton()
    private let transcribe = NSButton(
        checkboxWithTitle: "Transcribe after recording",
        target: nil,
        action: nil
    )
    private let echo = NSButton(
        checkboxWithTitle: "Cancel echo from speakers",
        target: nil,
        action: nil
    )
    private let modelStatus = NSTextField(labelWithString: "")
    private let modelButton = NSButton(title: "", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        let path = recordingsPath?() ?? Config.defaultRoot.path
        pathLabel.stringValue = path
        pathLabel.toolTip = path
        retention.selectItem(withTitle: Config.audioRetention().title)
        transcribe.state = Config.transcriptionEnabled() ? .on : .off
        echo.state = Config.micVoiceProcessing() ? .on : .off
        refreshModel()
    }

    func updateModelDownload(_ status: ModelDownload.Status) {
        switch status {
        case .idle:
            refreshModel()
        case .downloading(let fraction):
            modelStatus.stringValue = "Downloading - \(Int(fraction * 100))%"
            modelButton.isEnabled = false
        case .waitingForNetwork:
            refreshModel()
        case .failed:
            modelStatus.stringValue = "Download failed"
            modelButton.title = "Download"
            modelButton.isEnabled = true
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
        ])

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let change = NSButton(
            title: "Change…",
            target: self,
            action: #selector(changeFolderClicked)
        )
        stack.addArrangedSubview(section("Recordings"))
        stack.addArrangedSubview(row(label: "Folder", controls: [pathLabel, change]))

        retention.addItems(withTitles: Config.AudioRetention.allCases.map(\.title))
        retention.target = self
        retention.action = #selector(retentionChanged)
        stack.addArrangedSubview(row(label: "Audio", controls: [retention]))

        echo.target = self
        echo.action = #selector(echoChanged)
        echo.toolTip = "Use when recording through loudspeakers. Costs about 8 dB on system audio."
        stack.addArrangedSubview(row(label: "", controls: [echo]))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(section("Transcription"))
        transcribe.target = self
        transcribe.action = #selector(transcriptionChanged)
        stack.addArrangedSubview(row(label: "", controls: [transcribe]))

        let engine = NSPopUpButton()
        engine.addItem(withTitle: "Parakeet TDT 0.6B v2")
        engine.isEnabled = false
        stack.addArrangedSubview(row(label: "Engine", controls: [engine]))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(section("Models"))
        modelButton.target = self
        modelButton.action = #selector(modelClicked)
        stack.addArrangedSubview(row(label: "Transcription", controls: [modelStatus, modelButton]))
    }

    private func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func row(label: String, controls: [NSView]) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [title] + controls)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: 512).isActive = true
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 512).isActive = true
        return box
    }

    private func refreshModel() {
        if ModelDownload.isCached {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            modelStatus.stringValue = "Downloaded (\(formatter.string(fromByteCount: ModelDownload.cachedBytes)))"
            modelButton.title = "Remove…"
        } else {
            modelStatus.stringValue = "Not downloaded"
            modelButton.title = "Download"
        }
        modelButton.isEnabled = true
    }

    @objc private func changeFolderClicked() {
        onChangeRecordingsFolder?()
        refresh()
    }

    @objc private func retentionChanged() {
        guard
            let title = retention.selectedItem?.title,
            let selected = Config.AudioRetention.allCases.first(where: { $0.title == title })
        else { return }
        let current = Config.audioRetention()
        guard selected != current else { return }

        if selected != .indefinitely {
            let alert = NSAlert()
            if selected == .thirtyDays {
                alert.messageText = "Apply 30-day audio retention?"
                alert.informativeText = "Audio from completed transcripts older than 30 days will be deleted now. Transcripts remain, but the audio cannot be recovered or re-transcribed."
                alert.addButton(withTitle: "Apply")
            } else {
                alert.messageText = "Delete transcribed audio?"
                alert.informativeText = "Audio from every completed transcript will be deleted now. Transcripts remain, but the audio cannot be recovered or re-transcribed."
                alert.addButton(withTitle: "Delete Audio")
            }
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                retention.selectItem(withTitle: current.title)
                return
            }
        }

        Config.setAudioRetention(selected)
        onRetentionChanged?()
    }

    @objc private func transcriptionChanged() {
        Config.setTranscriptionEnabled(transcribe.state == .on)
    }

    @objc private func echoChanged() {
        Config.setMicVoiceProcessing(echo.state == .on)
    }

    @objc private func modelClicked() {
        if ModelDownload.isCached {
            let alert = NSAlert()
            alert.messageText = "Remove transcription models?"
            alert.informativeText = "This frees the downloaded model storage. Quill will need to download the models again before it can transcribe."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            modelStatus.stringValue = "Removing…"
            modelButton.isEnabled = false
            onRemoveModels?()
        } else {
            modelStatus.stringValue = "Downloading - 0%"
            modelButton.isEnabled = false
            onDownloadModels?()
        }
    }
}
