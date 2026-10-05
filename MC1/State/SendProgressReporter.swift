import Foundation
import MC1Services

/// Turns DM send events into Live Activity progress.
///
/// Tracks one send at a time: the most recently active DM owns the display, so a
/// second concurrent DM replaces the first. Channel messages are ignored.
@MainActor
final class SendProgressReporter {
  private let liveActivityManager: LiveActivityManager
  private let dataStore: PersistenceStore

  private var current: Tracked?
  private var tasks: [Task<Void, Never>] = []

  private struct Tracked {
    let messageID: UUID
    let contactID: UUID
    var progress: SendProgress
  }

  init(liveActivityManager: LiveActivityManager, dataStore: PersistenceStore) {
    self.liveActivityManager = liveActivityManager
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
        await self?.handleRepeat(messageID: event.messageID, count: event.count)
      }
    })
  }

  func stop() {
    for task in tasks { task.cancel() }
    tasks.removeAll()
    current = nil
  }

  private func handle(_ event: MessageStatusEvent) async {
    switch event {
    case let .statusResolved(messageID, status, _):
      switch status {
      case .sent: await update(messageID: messageID) { $0.phase = .sent }
      case .delivered: await update(messageID: messageID) { $0.phase = .delivered }
      case .failed: await update(messageID: messageID) { $0.phase = .failed }
      case .pending, .sending, .retrying: break
      }
    case let .resent(messageID):
      await update(messageID: messageID) { $0.phase = .sent }
    case let .retrying(messageID, attempt, maxAttempts):
      await update(messageID: messageID) {
        $0.phase = .retrying
        $0.retry = attempt + 1
        $0.maxRetries = maxAttempts
      }
    case let .routingChanged(contactID, isFlood):
      guard isFlood, let current, current.contactID == contactID else { return }
      await update(messageID: current.messageID) { $0.phase = .flooding }
    case let .failed(messageID):
      await update(messageID: messageID) { $0.phase = .failed }
    }
  }

  private func handleRepeat(messageID: UUID, count: Int) async {
    guard current?.messageID == messageID else { return }
    await update(messageID: messageID) { $0.repeatsHeard = count }
  }

  /// Applies `change` to the tracked send, starting to track it first if it is a DM
  /// we haven't seen. Terminal phases are not overwritten by late events.
  private func update(messageID: UUID, _ change: (inout SendProgress) -> Void) async {
    if current?.messageID != messageID {
      guard let tracked = await beginTracking(messageID: messageID) else { return }
      current = tracked
    }
    guard var tracked = current, !tracked.progress.phase.isTerminal else { return }
    change(&tracked.progress)
    current = tracked
    await liveActivityManager.updateSendProgress(tracked.progress)
  }

  private func beginTracking(messageID: UUID) async -> Tracked? {
    guard let message = try? await dataStore.fetchMessage(id: messageID),
          message.isOutgoing,
          let contactID = message.contactID,
          let contact = try? await dataStore.fetchContact(id: contactID) else { return nil }
    return Tracked(
      messageID: messageID,
      contactID: contactID,
      progress: SendProgress(
        recipient: contact.displayName,
        phase: .sent,
        retry: 0,
        maxRetries: 0,
        repeatsHeard: message.heardRepeats
      )
    )
  }
}
