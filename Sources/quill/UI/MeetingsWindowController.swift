import AppKit

/// Earlier meetings, newest first, to review, open or find. It is a chooser
/// that closes once used, so Settings stays the only persistent window.
@MainActor
final class MeetingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onReview: ((URL) -> Void)?
    var onOpenTranscript: ((URL) -> Void)?
    var isRecording: () -> Bool = { false }

    private let root: () -> URL
    private let presence: ApplicationPresenceController
    private var meetings: [Meeting] = []
    private let table = NSTableView()
    private let reviewButton = NSButton(title: "Review", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Transcript", target: nil, action: nil)
    private let finderButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private enum Column: String, CaseIterable {
        case meeting = "Meeting", length = "Length", people = "People", status = "Status"

        var width: CGFloat {
            switch self {
            case .meeting: 190
            case .length: 64
            case .people: 300
            case .status: 110
            }
        }
    }

    init(root: @escaping () -> URL, presence: ApplicationPresenceController) {
        self.root = root
        self.presence = presence
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meetings"
        window.minSize = NSSize(width: 560, height: 280)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        reload()
        guard let window else { return }
        presence.present(window)
        window.makeFirstResponder(table)
    }

    func reload() {
        meetings = Meeting.all(in: root())
        table.reloadData()
        if !meetings.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updateButtons()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { meetings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else {
            return nil
        }
        let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        field.identifier = id
        field.lineBreakMode = .byTruncatingTail
        let meeting = meetings[row]
        switch column {
        case .meeting: field.stringValue = meeting.title
        case .length: field.stringValue = meeting.durationSeconds.map { TranscriptDocument.minutes($0 * 1000) } ?? ""
        case .people: field.stringValue = meeting.people.joined(separator: ", ")
        case .status: field.stringValue = Self.status(meeting.state)
        }
        field.textColor = column == .status ? .secondaryLabelColor : .labelColor
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    static func status(_ state: Meeting.State) -> String {
        switch state {
        case .ready: ""
        case .needsNames: "Needs names"
        case .transcribing: "Transcribing"
        case .finishing: "Finishing audio"
        case .recording: "Recording"
        case .empty: "No audio"
        }
    }

    // MARK: - Actions

    private var selected: Meeting? {
        meetings.indices.contains(table.selectedRow) ? meetings[table.selectedRow] : nil
    }

    private var canReview: Bool {
        guard let selected, !isRecording() else { return false }
        return TranscriptStore(session: selected.folder).isReviewable
    }

    private func updateButtons() {
        reviewButton.isEnabled = canReview
        reviewButton.toolTip = isRecording() ? "Review is unavailable while Quill is recording." : nil
        openButton.isEnabled = selected?.markdownURL != nil
    }

    @objc private func reviewClicked() {
        guard canReview, let folder = selected?.folder else { return }
        close()
        onReview?(folder)
    }

    @objc private func openClicked() {
        guard let folder = selected?.folder, selected?.markdownURL != nil else { return }
        close()
        onOpenTranscript?(folder)
    }

    @objc private func finderClicked() {
        let folder = selected?.folder
        close()
        if let folder {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSWorkspace.shared.open(root())
        }
    }

    @objc private func cancelClicked() {
        close()
    }

    @objc private func rowDoubleClicked() {
        guard table.clickedRow >= 0 else { return }
        if canReview {
            reviewClicked()
        } else {
            openClicked()
        }
    }

    // MARK: - Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.rawValue
            tableColumn.width = column.width
            tableColumn.minWidth = 48
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.setAccessibilityLabel("Meetings")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for (button, action) in [
            (reviewButton, #selector(reviewClicked)),
            (openButton, #selector(openClicked)),
            (finderButton, #selector(finderClicked)),
            (cancelButton, #selector(cancelClicked)),
        ] {
            button.target = self
            button.action = action
        }
        reviewButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [finderButton, openButton, spacer, cancelButton, reviewButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 14),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        table.nextKeyView = finderButton
        finderButton.nextKeyView = openButton
        openButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = reviewButton
        reviewButton.nextKeyView = table
    }
}
