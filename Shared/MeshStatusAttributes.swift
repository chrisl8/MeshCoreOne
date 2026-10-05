import ActivityKit
import Foundation

struct MeshStatusAttributes: ActivityAttributes {
  let deviceName: String

  /// Stable per-radio identity used to match a same-device reconnect (deviceName is a
  /// user-editable display value, not an identity axis). Optional so an activity persisted
  /// by an older build, whose attributes had no radioID, still decodes after an app update.
  let radioID: UUID?

  struct ContentState: Codable, Hashable {
    var isConnected: Bool
    var batteryPercent: Int?
    var packetsPerMinute: Int
    var unreadCount: Int
    var disconnectedDate: Date?
    /// In-flight (or just-finished) DM send. Optional so an activity persisted by an
    /// older build still decodes.
    var send: SendProgress?

    var antennaIconName: String {
      isConnected
        ? "antenna.radiowaves.left.and.right"
        : "antenna.radiowaves.left.and.right.slash"
    }
  }
}

/// Progress of the DM send currently shown on the Live Activity.
struct SendProgress: Codable, Hashable {
  enum Phase: String, Codable {
    /// Radio accepted the packet; waiting for the recipient's ACK.
    case sent
    case retrying
    /// Direct routing gave up; now flooding.
    case flooding
    /// Quick attempts are used up; waiting out a backoff before the next try.
    case waiting
    case delivered
    case failed

    var isTerminal: Bool { self == .delivered || self == .failed }
  }

  var recipient: String
  var phase: Phase
  /// 1-based retry (`.retrying`) or backoff round (`.waiting`) number; 0 otherwise.
  var retry: Int
  var maxRetries: Int
  /// When the next backoff try starts; only set while `.waiting`.
  var retryAt: Date?
  /// Repeaters heard forwarding the message so far.
  var repeatsHeard: Int

  var iconName: String {
    switch phase {
    case .sent, .retrying: "paperplane.fill"
    case .flooding: "dot.radiowaves.left.and.right"
    case .waiting: "clock.fill"
    case .delivered: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
  }

  var isFailure: Bool { phase == .failed }

  private var heardText: String {
    switch repeatsHeard {
    case 0: "no repeats heard"
    case 1: "1 repeater heard"
    default: "\(repeatsHeard) repeaters heard"
    }
  }

  /// One-line status, e.g. "Retry 2/4 · 1 repeater heard".
  var statusText: String {
    switch phase {
    case .sent: "Sent · waiting for ACK" + (repeatsHeard > 0 ? " · \(heardText)" : "")
    case .retrying: "Retry \(retry)/\(maxRetries) · \(heardText)"
    case .flooding: "Flooding · \(heardText)"
    case .waiting: "Retry \(retry)/\(maxRetries) at \(retryAt?.formatted(date: .omitted, time: .shortened) ?? "—") · \(heardText)"
    case .delivered: "Delivered"
    case .failed: "Failed · \(heardText)"
    }
  }
}
