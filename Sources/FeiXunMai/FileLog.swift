import Foundation

/// Plain-text log at ~/Library/Logs/VibeDeck.log.
///
/// The unified log does not keep this ad-hoc signed app's messages, so the
/// voice path is diagnosed from this file. Writes are serialised on a private
/// queue and the file is truncated at launch when it grows past 4 MB.
enum FileLog {
    static let url: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        return base.appendingPathComponent("VibeDeck.log")
    }()

    private static let queue = DispatchQueue(label: "vibedeck.filelog")
    private static var truncated = false

    static func write(_ message: String) {
        queue.async {
            if !truncated {
                truncated = true
                if let size = try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.size] as? Int, size > 4 << 20 {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
