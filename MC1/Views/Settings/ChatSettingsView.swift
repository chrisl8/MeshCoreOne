import MC1Services
import SwiftUI

struct ChatSettingsView: View {
  @Environment(\.appTheme) private var theme
  @AppStorage(AppStorageKey.replyWithQuote.rawValue) private var replyWithQuote = AppStorageKey.defaultReplyWithQuote

  @AppStorage(CorescopeService.baseURLDefaultsKey) private var corescopeURL = CorescopeService.defaultBaseURL

  var body: some View {
    List {
      Section {
        TextField(L10n.Settings.Corescope.placeholder, text: $corescopeURL)
          .keyboardType(.URL)
          .textContentType(.URL)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
      } header: {
        Text(L10n.Settings.Corescope.title)
      } footer: {
        Text(L10n.Settings.Corescope.footer)
      }
      .themedRowBackground(theme)

      Section {
        Toggle(isOn: $replyWithQuote) {
          TintedLabel(L10n.Settings.ReplyWithQuote.toggle, systemImage: "text.quote")
        }
      } footer: {
        Text(L10n.Settings.ReplyWithQuote.footer)
      }
      .themedRowBackground(theme)

      LinkPreviewSettingsSection()
      MapPreviewSettingsSection()
      MessagesSettingsSection()
      RadioCleanupSection()
    }
    .themedCanvas(theme)
    .navigationTitle(L10n.Settings.ChatSettings.title)
    .navigationBarTitleDisplayMode(.inline)
  }
}
