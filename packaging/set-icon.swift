import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let icon = NSImage(contentsOfFile: CommandLine.arguments[1]),
      NSWorkspace.shared.setIcon(icon, forFile: CommandLine.arguments[2])
else {
    FileHandle.standardError.write(Data("couldn't set custom icon\n".utf8))
    exit(1)
}
