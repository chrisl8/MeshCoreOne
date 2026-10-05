import Foundation
import SwiftData

/// Opt-in "keep trying" state for one outgoing DM.
///
/// A row exists only for messages the user armed with persistent retry. It lives
/// beside `Message` instead of on it so the feature stays self-contained: no
/// change to the message schema, its DTO, or the backup format.
///
/// `round` counts backoff retries already scheduled; `nextRetryAt` is set while a
/// retry is waiting and cleared once it has been handed to the send queue.
@Model
public final class PersistentRetry {
  #Index<PersistentRetry>([\.radioID])

  @Attribute(.unique)
  public var messageID: UUID

  public var contactID: UUID
  public var radioID: UUID
  public var round: Int = 0
  public var nextRetryAt: Date?

  public init(messageID: UUID, contactID: UUID, radioID: UUID, round: Int = 0, nextRetryAt: Date? = nil) {
    self.messageID = messageID
    self.contactID = contactID
    self.radioID = radioID
    self.round = round
    self.nextRetryAt = nextRetryAt
  }
}

public struct PersistentRetryDTO: Sendable, Equatable {
  public let messageID: UUID
  public let contactID: UUID
  public let radioID: UUID
  public let round: Int
  public let nextRetryAt: Date?

  init(from model: PersistentRetry) {
    messageID = model.messageID
    contactID = model.contactID
    radioID = model.radioID
    round = model.round
    nextRetryAt = model.nextRetryAt
  }
}
