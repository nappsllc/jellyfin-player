import Foundation

/// A small on-device log of what happened to each song's cover (loaded from where, how long it took,
/// when it was announced to the lock screen / car, and when the system asked for the picture).
/// Shown under Settings → Cover log so a problem seen in the car can be traced afterwards.
/// Nothing leaves the phone unless the user copies or shares it.
final class DiagLog: @unchecked Sendable {
    static let shared = DiagLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let file: URL
    private let formatter: DateFormatter
    private static let maxLines = 500

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        file = base.appendingPathComponent("cover-log.txt")
        formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        if let saved = try? String(contentsOf: file, encoding: .utf8) {
            lines = saved.split(separator: "\n").map(String.init).suffix(Self.maxLines)
        }
    }

    func add(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append("\(formatter.string(from: Date()))  \(message)")
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        lines = []
        try? FileManager.default.removeItem(at: file)
    }
}
