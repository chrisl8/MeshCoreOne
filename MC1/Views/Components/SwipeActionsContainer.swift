import SwiftUI

extension View {
  /// Enables row `.swipeActions` inside this `ScrollView` on iOS 27.
  /// Earlier OSes have no container API, so the row modifiers stay inert outside `List`.
  @ViewBuilder
  func swipeActionsContainerIfAvailable() -> some View {
    // LOCAL: iOS 27 SDK (Xcode 27) not installed; API compiled out so Xcode 26.5 builds.
    self
  }
}
