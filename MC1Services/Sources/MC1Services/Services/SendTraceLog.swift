import Foundation

/// Diagnostic: appends one line per DM transmission to `send-trace.log` in
/// Application Support, so a send count can be read off the device instead of
/// inferred from repeater echoes. Remove once persistent retry is settled.
enum SendTraceLog {
  private static let lock = NSLock()

  static func record(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    let url = dir.appendingPathComponent("send-trace.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
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
