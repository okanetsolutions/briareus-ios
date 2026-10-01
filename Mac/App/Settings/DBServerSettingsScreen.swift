// Placeholder until this screen is ported from the Windows client.
import SwiftUI

struct DBServerSettingsScreen: View {
    var row: JSON?
    var defaults: JSON?
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Database server")
            EmptyNote(title: "Not yet ported.")
            Spacer()
        }
    }
}
