// Placeholder until this screen is ported from the Windows client.
import SwiftUI

struct PullFilesScreen: View {
    var repo: String
    var number: Int
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Files changed")
            EmptyNote(title: "Not yet ported.")
            Spacer()
        }
    }
}
