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
        guard let date = recorded(dir) else { return dir.lastPathComponent }
        return "\(timeFormat.string(from: date)) recording"
    }

    static func dated(_ dir: URL) -> String {
        guard let date = recorded(dir) else { return dir.lastPathComponent }
        return dateTimeFormat.string(from: date)
    }

    /// A second recording in the same minute gets a numeric suffix (`-2`). Any
    /// other suffix was added by hand, so that folder keeps its name.
    static func recorded(_ dir: URL) -> Date? {
        let name = dir.lastPathComponent
        let stamp = name.prefix(15)
        let suffix = name.dropFirst(15)
        guard suffix.isEmpty
            || (suffix.count > 1 && suffix.first == "-" && suffix.dropFirst().allSatisfy(\.isNumber))
        else { return nil }
        return folderFormat.date(from: String(stamp))
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
