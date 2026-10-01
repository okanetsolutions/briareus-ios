// Placeholder until this screen is ported from the Windows client.
import SwiftUI

struct ConversationScreen: View {
    var sessionID: String
    var initial: JSON?
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Conversation")
            EmptyNote(title: "Not yet ported.")
            Spacer()
        }
    }
}
