import Foundation
import MC1Services
import Observation

/// Progress of a DM that is still being retried, for the Chats-list banner.
struct PendingSendProgress: Equatable {
  enum Phase: Equatable {
    /// Radio accepted the packet; waiting for the recipient's ACK.
    case sent
    case retrying
    /// Direct routing gave up; now flooding.
    case flooding
    /// The retry burst is spent; waiting out a backoff round before the next send.
    case waiting
  }

  var recipient: String
  var phase: Phase
  /// Retry index and total as the bubble footer counts them (`Message.retryAttempt`).
  var retry: Int
  var maxRetries: Int
  /// When the next backoff send starts; only set while `.waiting`.
  var retryAt: Date?
  /// Repeaters heard forwarding the message so far.
  var repeatsHeard: Int

  var iconName: String {
    switch phase {
    case .sent, .retrying: "paperplane.fill"
    case .flooding: "dot.radiowaves.left.and.right"
    case .waiting: "clock.fill"
    }
  }

  private var heardText: String {
    switch repeatsHeard {
    case 0: "no echoes heard"
    case 1: "1 echo heard"
    default: "\(repeatsHeard) echoes heard"
    }
  }

  /// One line, e.g. "Send 3/5 · 1 echo heard". Counts like the bubble footer (`sendAttemptProgress`).
  var statusText: String {
    switch phase {
    case .sent: "Sent · waiting for ACK" + (repeatsHeard > 0 ? " · \(heardText)" : "")
    case .retrying: "Send \(retry + 2)/\(maxRetries + 1) · \(heardText)"
    case .flooding: "Flooding · \(heardText)"
    case .waiting:
      "Send \(retry + 2)/\(maxRetries + 1) at \(retryAt?.formatted(date: .omitted, time: .shortened) ?? "—") · \(heardText)"
    }
  }
}

/// Follows DM send events and keeps one banner for a DM that is still retrying.
///
/// The banner belongs to one message: other DMs sending meanwhile neither replace nor
/// clear it. It stays up through the ACK wait between backoff rounds, and goes away
/// when that message is delivered or fails. Channel messages are ignored.
@Observable
@MainActor
final class PendingSendTracker {
  struct Banner: Equatable {
    let contactID: UUID
    let progress: PendingSendProgress
  }

  private(set) var banner: Banner?
  @ObservationIgnored private var bannerMessageID: UUID?

  /// Called when the banner's message enters or leaves a backoff wait.
  @ObservationIgnored var onWaitingChanged: ((Bool) -> Void)?

  @ObservationIgnored private let dataStore: PersistenceStore
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []

  init(dataStore: PersistenceStore) {
    self.dataStore = dataStore
  }

  /// Subscribes to both streams synchronously, then consumes them.
  func start(messageService: MessageService, heardRepeatsService: HeardRepeatsService) {
    stop()
    let statusEvents = messageService.statusEvents()
    let repeatEvents = heardRepeatsService.events()
    tasks.append(Task { [weak self] in
      for await event in statusEvents {
        await self?.handle(event)
      }
    })
    tasks.append(Task { [weak self] in
      for await event in repeatEvents {
        self?.handleRepeat(messageID: event.messageID, count: event.count)
      }
    })
  }

  func stop() {
    for task in tasks { task.cancel() }
    tasks.removeAll()
    setBanner(nil, messageID: nil)
  }

  private func handle(_ event: MessageStatusEvent) async {
    switch event {
    case let .statusResolved(messageID, status, _):
      switch status {
      case .sent: update(messageID: messageID) { $0.phase = .sent }
      case .delivered, .failed: finish(messageID: messageID)
      case .pending, .sending, .retrying: break
      }
    case let .resent(messageID):
      update(messageID: messageID) { $0.phase = .sent }
    case let .retrying(messageID, attempt, maxAttempts):
      await begin(messageID: messageID)
      update(messageID: messageID) {
        $0.phase = .retrying
        $0.retry = attempt
        $0.maxRetries = maxAttempts
      }
    case let .backoffScheduled(messageID, _, _, notBefore):
      await begin(messageID: messageID)
      update(messageID: messageID) {
        $0.phase = .waiting
        $0.retryAt = notBefore
      }
    case let .routingChanged(contactID, isFlood):
      guard isFlood, let banner, banner.contactID == contactID, let bannerMessageID else { return }
      update(messageID: bannerMessageID) { $0.phase = .flooding }
    case let .failed(messageID):
      finish(messageID: messageID)
    case .reactionAccepted:
      break
    }
  }

  private func handleRepeat(messageID: UUID, count: Int) {
    update(messageID: messageID) { $0.repeatsHeard = count }
  }

  /// Takes the banner for an outgoing DM if no other message holds it.
  private func begin(messageID: UUID) async {
    guard bannerMessageID == nil else { return }
    guard let message = try? await dataStore.fetchMessage(id: messageID),
          message.isOutgoing,
          let contactID = message.contactID,
          let contact = try? await dataStore.fetchContact(id: contactID),
          bannerMessageID == nil else { return }
    let progress = PendingSendProgress(
      recipient: contact.displayName,
      phase: .sent,
      retry: message.retryAttempt,
      maxRetries: message.maxRetryAttempts,
      retryAt: nil,
      repeatsHeard: message.heardRepeats
    )
    setBanner(Banner(contactID: contactID, progress: progress), messageID: messageID)
  }

  /// Changes the banner if `messageID` owns it.
  private func update(messageID: UUID, _ change: (inout PendingSendProgress) -> Void) {
    guard bannerMessageID == messageID, let banner else { return }
    var progress = banner.progress
    change(&progress)
    if progress.phase != .waiting { progress.retryAt = nil }
    setBanner(Banner(contactID: banner.contactID, progress: progress), messageID: messageID)
  }

  private func finish(messageID: UUID) {
    guard bannerMessageID == messageID else { return }
    setBanner(nil, messageID: nil)
  }

  private func setBanner(_ new: Banner?, messageID: UUID?) {
    let wasWaiting = banner?.progress.phase == .waiting
    banner = new
    bannerMessageID = messageID
    let isWaiting = new?.progress.phase == .waiting
    if wasWaiting != isWaiting { onWaitingChanged?(isWaiting) }
  }
}
