import Foundation

/// Turns a session directory into something a person reads.
///
/// Folders are named `yyyy.MM.dd-HHmm` because that sorts and collides
/// usefully on disk, but a filesystem identifier has no business appearing in
/// a menu or a notification.
enum SessionName {
    /// "2:14 PM recording", or the folder name if it doesn't parse — a session
    /// created by hand should still be nameable.
    static func spoken(_ dir: URL) -> String {
        guard let date = folderFormat.date(from: dir.lastPathComponent) else {
            return dir.lastPathComponent
        }
        return "\(timeFormat.string(from: date)) recording"
    }

    static func dated(_ dir: URL) -> String {
        guard let date = folderFormat.date(from: dir.lastPathComponent) else {
            return dir.lastPathComponent
        }
        return dateTimeFormat.string(from: date)
    }

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dateTimeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
