// Placeholder until this screen is ported from the Windows client.
import SwiftUI

struct BoardScreen: View {
    var repo: String
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Board")
            EmptyNote(title: "Not yet ported.")
            Spacer()
        }
    }
}
