import Foundation
import OSLog

/// Result of checking a sent channel message against a CoreScope instance.
/// Raw values are persisted on `Message.corescopeStateRaw`; never renumber.
public enum CorescopeState: Int, Sendable, Hashable {
  /// No check ran (feature off, DM, channel not tracked by CoreScope, or incoming).
  case none = 0
  /// Polling; the message has not shown up on CoreScope yet.
  case checking = 1
  /// CoreScope has the message; `corescopeHeard` holds its repeat count.
  case seen = 2
  /// Final poll finished without finding the message.
  case notSeen = 3
  /// CoreScope could not be reached (no internet, server down, bad response).
  case offline = 4
}

public struct CorescopeEvent: Sendable {
  public let messageID: UUID
  public let state: CorescopeState
  public let heard: Int
}

/// After a channel message is sent, polls a CoreScope instance's public JSON API to see
/// whether any observer picked the message up and how many times it was heard.
///
/// Matching is by the wire sender timestamp plus message text, which the app already
/// stores for the sent message. Results are persisted on the message and broadcast so
/// open conversations update in place.
public actor CorescopeService {
  /// UserDefaults key holding the CoreScope base URL. Empty disables the feature.
  public static let baseURLDefaultsKey = "corescopeBaseURL"
  public static let defaultBaseURL = "https://corescope.mspmesh.org"

  /// Seconds after send at which to poll. The last poll decides `.notSeen`.
  static let pollOffsets: [TimeInterval] = [3, 8, 20, 45, 90]
  private static let channelListTTL: TimeInterval = 600

  private let dataStore: any PersistenceStoreProtocol
  private let fetch: @Sendable (URL) async throws -> Data
  private let defaults: UserDefaults
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "CorescopeService")
  private nonisolated let eventBroadcaster = EventBroadcaster<CorescopeEvent>()

  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var channelNames: (names: Set<String>, fetchedAt: Date)?

  init(
    dataStore: any PersistenceStoreProtocol,
    defaults: UserDefaults = .standard,
    fetch: (@Sendable (URL) async throws -> Data)? = nil
  ) {
    self.dataStore = dataStore
    self.defaults = defaults
    self.fetch = fetch ?? { url in
      var request = URLRequest(url: url, timeoutInterval: 8)
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
      }
      return data
    }
  }

  public nonisolated func events() -> AsyncStream<CorescopeEvent> {
    eventBroadcaster.subscribe()
  }

  nonisolated func finishEvents() {
    eventBroadcaster.finish()
  }

  /// Cancels all polling (disconnect / teardown).
  public func cancelAll() {
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
  }

  /// Starts (or restarts, for a resend) checking one sent channel message.
  public func track(messageID: UUID) async {
    guard let base = configuredBaseURL() else { return }
    guard let message = try? await dataStore.fetchMessage(id: messageID),
          message.direction == .outgoing,
          let channelIndex = message.channelIndex,
          message.reactionTargetMessageID == nil,
          let channel = try? await dataStore.fetchChannel(radioID: message.radioID, index: channelIndex)
    else { return }

    tasks[messageID]?.cancel()
    let text = message.text
    let timestamp = message.timestamp
    let channelName = channel.name
    tasks[messageID] = Task { [weak self] in
      await self?.run(
        messageID: messageID, base: base, channelName: channelName,
        text: text, timestamp: timestamp
      )
    }
  }

  private func configuredBaseURL() -> URL? {
    let raw = (defaults.string(forKey: Self.baseURLDefaultsKey) ?? Self.defaultBaseURL)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
    return url
  }

  private func run(messageID: UUID, base: URL, channelName: String, text: String, timestamp: UInt32) async {
    defer { tasks[messageID] = nil }
    var lastHeard = 0
    var everSeen = false
    var started = false
    var elapsed: TimeInterval = 0

    for (index, offset) in Self.pollOffsets.enumerated() {
      let isLast = index == Self.pollOffsets.count - 1
      try? await Task.sleep(for: .seconds(offset - elapsed))
      elapsed = offset
      if Task.isCancelled { return }

      do {
        guard let apiName = try await resolveChannel(named: channelName, base: base) else {
          // CoreScope does not track this channel: leave no chip.
          if started { await publish(messageID, .none, 0) }
          return
        }
        if !started {
          started = true
          await publish(messageID, .checking, 0)
        }
        if let repeats = try await lookup(messageID: messageID, base: base, channel: apiName, text: text, timestamp: timestamp) {
          everSeen = true
          lastHeard = repeats
          await publish(messageID, .seen, repeats)
        } else if isLast, !everSeen {
          await publish(messageID, .notSeen, 0)
        }
      } catch is CancellationError {
        return
      } catch {
        logger.debug("CoreScope poll failed: \(error.localizedDescription)")
        started = true
        if !everSeen { await publish(messageID, .offline, 0) }
      }
    }
    _ = lastHeard
  }

  private func publish(_ messageID: UUID, _ state: CorescopeState, _ heard: Int) async {
    try? await dataStore.updateMessageCorescope(id: messageID, state: state, heard: heard)
    eventBroadcaster.yield(CorescopeEvent(messageID: messageID, state: state, heard: heard))
  }

  /// Maps an app channel name to CoreScope's channel key, or nil if it isn't tracked.
  private func resolveChannel(named name: String, base: URL) async throws -> String? {
    if channelNames == nil || Date().timeIntervalSince(channelNames!.fetchedAt) > Self.channelListTTL {
      let data = try await fetch(base.appending(path: "api/channels"))
      let list = try JSONDecoder().decode(ChannelList.self, from: data)
      channelNames = (Set(list.channels.map(\.name)), Date())
    }
    let wanted = name.lowercased()
    return channelNames?.names.first { $0.lowercased() == wanted }
  }

  /// Returns CoreScope's repeat count if the message is present, nil if not found.
  private func lookup(
    messageID: UUID, base: URL, channel: String, text: String, timestamp: UInt32
  ) async throws -> Int? {
    var components = URLComponents(
      url: base.appending(path: "api/channels/\(channel)/messages"), resolvingAgainstBaseURL: false
    )
    components?.queryItems = [URLQueryItem(name: "limit", value: "50")]
    guard let url = components?.url else { throw URLError(.badURL) }
    let data = try await fetch(url)
    let page = try JSONDecoder().decode(MessagePage.self, from: data)
    guard let match = page.messages.last(where: {
      $0.sender_timestamp == timestamp && $0.text == text
    }) else { return nil }
    return max(match.repeats ?? 1, 1)
  }

  private struct ChannelList: Decodable {
    struct Entry: Decodable { let name: String }
    let channels: [Entry]
  }

  private struct MessagePage: Decodable {
    struct Entry: Decodable {
      let text: String
      let sender_timestamp: UInt32?
      let repeats: Int?
    }
    let messages: [Entry]
  }
}
