import SwiftUI

/// Chats-list banner for a DM that is still being retried. Tapping it opens that
/// conversation, so you don't have to dig for the contact after the app opens
/// somewhere else.
struct PendingSendBanner: View {
  let progress: SendProgress
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 10) {
        Image(systemName: progress.iconName)
          .font(.headline)
        VStack(alignment: .leading, spacing: 2) {
          Text(progress.recipient)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Text(progress.statusText)
            .font(.caption)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      .background(Color.orange)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityHint("Opens the conversation")
  }
}
