// Placeholder until this screen is ported from the Windows client.
import SwiftUI

struct SessionPanel: View {
    var session: JSON
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Pull request")
            EmptyNote(title: "Not yet ported.")
            Spacer()
        }
    }
}
