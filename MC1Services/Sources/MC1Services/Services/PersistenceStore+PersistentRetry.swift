import Foundation
import SwiftData

extension PersistenceStore {
  /// Marks a message for persistent retry. Idempotent per message.
  func armPersistentRetry(messageID: UUID, contactID: UUID, radioID: UUID) throws {
    if try fetchPersistentRetryModel(messageID: messageID) != nil { return }
    modelContext.insert(PersistentRetry(messageID: messageID, contactID: contactID, radioID: radioID))
    try modelContext.save()
  }

  func fetchPersistentRetry(messageID: UUID) throws -> PersistentRetryDTO? {
    try fetchPersistentRetryModel(messageID: messageID).map(PersistentRetryDTO.init(from:))
  }

  /// Records a scheduled retry (`nextRetryAt` set) or one handed to the queue (nil).
  func updatePersistentRetry(messageID: UUID, round: Int, nextRetryAt: Date?) throws {
    guard let model = try fetchPersistentRetryModel(messageID: messageID) else { return }
    model.round = round
    model.nextRetryAt = nextRetryAt
    try modelContext.save()
  }

  func clearPersistentRetry(messageID: UUID) throws {
    guard let model = try fetchPersistentRetryModel(messageID: messageID) else { return }
    modelContext.delete(model)
    try modelContext.save()
  }

  /// Retries still waiting on their timer, for rescheduling after a restart.
  func fetchScheduledPersistentRetries(radioID: UUID) throws -> [PersistentRetryDTO] {
    let targetRadioID = radioID
    let predicate = #Predicate<PersistentRetry> { row in
      row.radioID == targetRadioID && row.nextRetryAt != nil
    }
    return try modelContext.fetch(FetchDescriptor(predicate: predicate)).map(PersistentRetryDTO.init(from:))
  }

  private func fetchPersistentRetryModel(messageID: UUID) throws -> PersistentRetry? {
    let target = messageID
    let predicate = #Predicate<PersistentRetry> { $0.messageID == target }
    var descriptor = FetchDescriptor(predicate: predicate)
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }
}
