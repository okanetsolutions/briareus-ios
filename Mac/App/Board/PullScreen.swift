// Placeholder until this screen is ported from the Windows client.
import SwiftUI

struct PullScreen: View {
    var repo: String
    var number: Int
    var stack: JSON?
    var summary: JSON?
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Pull request")
            EmptyNote(title: "Not yet ported.")
            Spacer()
        }
    }
}
