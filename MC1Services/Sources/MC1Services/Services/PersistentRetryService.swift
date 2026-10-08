import Foundation

/// Backoff schedule for persistent retry.
public struct PersistentRetryPolicy: Sendable, Equatable {
  /// Wait before the first backoff retry; each later round doubles it.
  public var baseInterval: TimeInterval
  /// Backoff retries after the normal send loop has given up.
  public var maxRounds: Int

  public init(baseInterval: TimeInterval = 120, maxRounds: Int = 3) {
    self.baseInterval = baseInterval
    self.maxRounds = maxRounds
  }

  /// Wait before `round` (1-based): x, 2x, 4x, ...
  public func delay(forRound round: Int) -> TimeInterval {
    baseInterval * pow(2, Double(max(round, 1) - 1))
  }

  public static let `default` = PersistentRetryPolicy()
}

/// A scheduled backoff retry, reported to the caller so it can show progress.
public struct PersistentRetryPlan: Sendable, Equatable {
  public let round: Int
  public let maxRounds: Int
  public let retryAt: Date
  public let delay: TimeInterval
}

/// Keeps retrying opted-in DMs after the normal retry loop has given up.
///
/// The send loop (`MessageService`) tries up to five times in quick succession,
/// then the ACK checker would mark the message failed. For a message armed with
/// persistent retry, the checker instead asks this service for a plan; the service
/// waits out the backoff and re-queues the message through the same path as the
/// manual retry button. After `maxRounds` the message fails normally.
public actor PersistentRetryService {
  private let dataStore: PersistenceStore
  /// Hands a retry to the send queue (`ChatSendQueueService.signalDMEnqueued` in production).
  private let enqueue: @Sendable (DirectMessageEnvelope) async -> Void
  private let policy: PersistentRetryPolicy
  private let now: @Sendable () -> Date
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "PersistentRetryService")

  private var timers: [UUID: Task<Void, Never>] = [:]

  init(
    dataStore: PersistenceStore,
    enqueue: @escaping @Sendable (DirectMessageEnvelope) async -> Void,
    policy: PersistentRetryPolicy = .default,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.dataStore = dataStore
    self.enqueue = enqueue
    self.policy = policy
    self.now = now
  }

  /// Opts a message in. Call right after the message is created.
  public func arm(messageID: UUID, contactID: UUID, radioID: UUID) async {
    do {
      try await dataStore.armPersistentRetry(messageID: messageID, contactID: contactID, radioID: radioID)
    } catch {
      logger.error("Failed to arm persistent retry for \(messageID): \(error.localizedDescription)")
    }
  }

  /// Whether the message was opted in to persistent retry.
  public func isArmed(_ messageID: UUID) async -> Bool {
    (try? await dataStore.fetchPersistentRetry(messageID: messageID)) != nil
  }

  /// For an armed message between backoff sends: puts the bubble back at
  /// "retrying n/N" so the round counter stays visible through the ACK wait instead
  /// of dropping to a bare "sent" spinner. Returns the round and total, or nil when
  /// the message is not in a backoff round.
  func holdRetryingStatus(for messageID: UUID) async -> (round: Int, maxRounds: Int)? {
    do {
      guard let record = try await dataStore.fetchPersistentRetry(messageID: messageID),
            record.round > 0 else { return nil }
      try await dataStore.updateMessageRetryStatus(
        id: messageID,
        status: .retrying,
        retryAttempt: record.round - 1,
        maxRetryAttempts: policy.maxRounds
      )
      return (record.round, policy.maxRounds)
    } catch {
      logger.error("Failed to hold retrying status for \(messageID): \(error.localizedDescription)")
      return nil
    }
  }

  /// True while the message has a queued send that has not run yet. The ACK expiry
  /// checker must not start another round then: the retry it would plan for is the
  /// one already waiting its turn in the send queue.
  func hasQueuedSend(_ messageID: UUID) async -> Bool {
    ((try? await dataStore.fetchPendingSendsForMessage(messageID: messageID)) ?? []).isEmpty == false
  }

  /// Backoff rounds already started for a message; 0 when it is not armed.
  public func round(for messageID: UUID) async -> Int {
    (try? await dataStore.fetchPersistentRetry(messageID: messageID))?.round ?? 0
  }

  /// Called when a message's ACK window has expired. Returns the plan for the next
  /// backoff retry, or nil when the message is not armed or has used every round
  /// (the caller then fails it as usual).
  func planRetry(for messageID: UUID) async -> PersistentRetryPlan? {
    do {
      guard let record = try await dataStore.fetchPersistentRetry(messageID: messageID) else { return nil }

      // Already waiting on a timer: report the same plan instead of burning a round.
      if let waitingUntil = record.nextRetryAt, waitingUntil > now() {
        return PersistentRetryPlan(
          round: record.round,
          maxRounds: policy.maxRounds,
          retryAt: waitingUntil,
          delay: waitingUntil.timeIntervalSince(now())
        )
      }

      let round = record.round + 1
      guard round <= policy.maxRounds else {
        try await dataStore.clearPersistentRetry(messageID: messageID)
        return nil
      }

      let delay = policy.delay(forRound: round)
      let retryAt = now().addingTimeInterval(delay)
      try await dataStore.updatePersistentRetry(messageID: messageID, round: round, nextRetryAt: retryAt)
      schedule(messageID: messageID, contactID: record.contactID, radioID: record.radioID, at: retryAt)
      logger.info("Persistent retry \(round)/\(policy.maxRounds) for \(messageID) in \(Int(delay))s")
      return PersistentRetryPlan(round: round, maxRounds: policy.maxRounds, retryAt: retryAt, delay: delay)
    } catch {
      logger.error("Failed to plan persistent retry for \(messageID): \(error.localizedDescription)")
      return nil
    }
  }

  /// Cuts every waiting backoff short because the user has moved. The retry does
  /// not use up a round (beyond the first): a new location may be in range, so it
  /// gets a fresh try without shortening the schedule if it still fails.
  public func retryNowForMovement() async {
    for messageID in Array(timers.keys) {
      timers[messageID]?.cancel()
      do {
        guard let record = try await dataStore.fetchPersistentRetry(messageID: messageID) else { continue }
        logger.info("Moved; retrying \(messageID) early")
        await fire(messageID: messageID, contactID: record.contactID, radioID: record.radioID, refundRound: true)
      } catch {
        logger.error("Movement retry failed for \(messageID): \(error.localizedDescription)")
      }
    }
  }

  /// Reschedules retries that were waiting when the app last stopped. Overdue ones
  /// fire immediately; the send queue then parks them until the radio is ready.
  func hydrate(radioID: UUID) async {
    do {
      for record in try await dataStore.fetchScheduledPersistentRetries(radioID: radioID) {
        guard let retryAt = record.nextRetryAt else { continue }
        schedule(messageID: record.messageID, contactID: record.contactID, radioID: radioID, at: retryAt)
      }
    } catch {
      logger.error("Failed to hydrate persistent retries: \(error.localizedDescription)")
    }
    await resumeAbandoned(radioID: radioID)
  }

  /// An armed message whose attempt was in flight when the app stopped has no timer
  /// and no ACK tracking (both live in memory), so nothing would ever retry or fail
  /// it. Treat its ACK window as expired: start the next round, or fail it if the
  /// rounds are used up.
  private func resumeAbandoned(radioID: UUID) async {
    do {
      for record in try await dataStore.fetchIdlePersistentRetries(radioID: radioID) {
        let messageID = record.messageID
        // Still queued to send: the queue will drive it.
        if try await !dataStore.fetchPendingSendsForMessage(messageID: messageID).isEmpty { continue }
        guard let message = try await dataStore.fetchMessage(id: messageID),
              message.status != .delivered, message.status != .failed else {
          try await dataStore.clearPersistentRetry(messageID: messageID)
          continue
        }
        if let plan = await planRetry(for: messageID) {
          try await dataStore.updateMessageRetryStatus(
            id: messageID,
            status: .retrying,
            retryAttempt: plan.round - 1,
            maxRetryAttempts: plan.maxRounds
          )
        } else {
          _ = try await dataStore.updateMessageStatusUnlessDelivered(id: messageID, status: .failed)
        }
      }
    } catch {
      logger.error("Failed to resume abandoned persistent retries: \(error.localizedDescription)")
    }
  }

  func shutdown() {
    for timer in timers.values { timer.cancel() }
    timers.removeAll()
  }

  private func schedule(messageID: UUID, contactID: UUID, radioID: UUID, at retryAt: Date) {
    timers[messageID]?.cancel()
    let wait = max(0, retryAt.timeIntervalSince(now()))
    timers[messageID] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(wait))
      guard !Task.isCancelled else { return }
      await self?.fire(messageID: messageID, contactID: contactID, radioID: radioID)
    }
  }

  private func fire(messageID: UUID, contactID: UUID, radioID: UUID, refundRound: Bool = false) async {
    timers[messageID] = nil
    do {
      guard let message = try await dataStore.fetchMessage(id: messageID),
            message.status != .delivered else {
        try await dataStore.clearPersistentRetry(messageID: messageID)
        return
      }
      guard let record = try await dataStore.fetchPersistentRetry(messageID: messageID) else { return }
      // Floor of 1 keeps "round > 0 means backoff send" true for the send that follows.
      let round = refundRound ? max(record.round - 1, 1) : record.round
      try await dataStore.updatePersistentRetry(messageID: messageID, round: round, nextRetryAt: nil)

      // Same path as the manual retry button: one transaction replaces any stale
      // queue row and flips the message to pending, then the queue is signalled.
      let envelope = DirectMessageEnvelope(messageID: messageID, contactID: contactID)
      let dto = PendingSendDTO(envelope: envelope, radioID: radioID)
      _ = try await dataStore.replacePendingSendForRetry(messageID: messageID, dto: dto)
      await enqueue(envelope)
    } catch {
      logger.error("Persistent retry fire failed for \(messageID): \(error.localizedDescription)")
    }
  }
}
