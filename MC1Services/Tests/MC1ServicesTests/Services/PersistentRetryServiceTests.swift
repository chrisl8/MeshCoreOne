// MC1Services/Tests/MC1ServicesTests/Services/PersistentRetryServiceTests.swift
import Foundation
@testable import MC1Services
import Testing

@Suite("PersistentRetryService Tests")
struct PersistentRetryServiceTests {
  @Test
  func `policy doubles the wait each round`() {
    let policy = PersistentRetryPolicy(baseInterval: 120, maxRounds: 3)

    #expect(policy.delay(forRound: 1) == 120)
    #expect(policy.delay(forRound: 2) == 240)
    #expect(policy.delay(forRound: 3) == 480)
  }

  @Test
  func `unarmed message gets no plan`() async throws {
    let (_, service) = try makeStoreAndService()

    let plan = await service.planRetry(for: UUID())

    #expect(plan == nil)
  }

  @Test
  func `armed message is planned through every round then released`() async throws {
    let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
    let (store, service) = try makeStoreAndService(
      policy: PersistentRetryPolicy(baseInterval: 60, maxRounds: 2),
      clock: clock
    )
    let messageID = UUID()
    await service.arm(messageID: messageID, contactID: UUID(), radioID: UUID())

    let first = await service.planRetry(for: messageID)
    #expect(first?.round == 1)
    #expect(first?.delay == 60)
    #expect(first?.retryAt == clock.now.addingTimeInterval(60))

    // Timer fired and cleared nextRetryAt; the retry failed again later.
    try await store.updatePersistentRetry(messageID: messageID, round: 1, nextRetryAt: nil)
    clock.advance(by: 300)
    let second = await service.planRetry(for: messageID)
    #expect(second?.round == 2)
    #expect(second?.delay == 120)

    try await store.updatePersistentRetry(messageID: messageID, round: 2, nextRetryAt: nil)
    let exhausted = await service.planRetry(for: messageID)
    #expect(exhausted == nil)
    #expect(try await store.fetchPersistentRetry(messageID: messageID) == nil)
  }

  @Test
  func `a message already waiting reports its plan without using a round`() async throws {
    let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
    let (_, service) = try makeStoreAndService(clock: clock)
    let messageID = UUID()
    await service.arm(messageID: messageID, contactID: UUID(), radioID: UUID())

    let first = await service.planRetry(for: messageID)
    clock.advance(by: 10)
    let again = await service.planRetry(for: messageID)

    #expect(first?.round == 1)
    #expect(again?.round == 1)
    #expect(again?.retryAt == first?.retryAt)
  }

  @Test
  func `an overdue retry is handed to the queue after hydrate`() async throws {
    let radioID = UUID()
    let contactID = UUID()
    let messageID = UUID()
    let queued = Queued()
    let (store, service) = try makeStoreAndService(enqueue: { await queued.add($0) })
    try await store.saveMessage(.testDirectMessage(
      id: messageID,
      radioID: radioID,
      contactID: contactID,
      status: .sent
    ))
    await service.arm(messageID: messageID, contactID: contactID, radioID: radioID)
    try await store.updatePersistentRetry(
      messageID: messageID,
      round: 1,
      nextRetryAt: Date().addingTimeInterval(-5)
    )

    await service.hydrate(radioID: radioID)
    try await Task.sleep(for: .milliseconds(300))

    #expect(await queued.envelopes.map(\.messageID) == [messageID])
    let record = try await store.fetchPersistentRetry(messageID: messageID)
    #expect(record?.nextRetryAt == nil)
    #expect(record?.round == 1)
  }

  // MARK: - Helpers

  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(by seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
  }

  private actor Queued {
    private(set) var envelopes: [DirectMessageEnvelope] = []
    func add(_ envelope: DirectMessageEnvelope) { envelopes.append(envelope) }
  }

  private func makeStoreAndService(
    policy: PersistentRetryPolicy = .default,
    clock: Clock = Clock(Date()),
    enqueue: @escaping @Sendable (DirectMessageEnvelope) async -> Void = { _ in }
  ) throws -> (PersistenceStore, PersistentRetryService) {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let store = PersistenceStore(modelContainer: container)
    let service = PersistentRetryService(
      dataStore: store,
      enqueue: enqueue,
      policy: policy,
      now: { clock.now }
    )
    return (store, service)
  }
}
