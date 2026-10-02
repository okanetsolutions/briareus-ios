// Placeholders until the board screens are ported. Delete this file once they are.
import SwiftUI

struct BoardScreen: View { let repo: String; var body: some View { Text(repo) } }
struct PullScreen: View { let repo: String; let number: Int; let stack: JSON?; let summary: JSON?; var body: some View { Text("#\(number)") } }
struct PullFilesScreen: View { let repo: String; let number: Int; var body: some View { Text("#\(number)") } }
struct IssueScreen: View { let repo: String; let issue: JSON; var body: some View { Text(repo) } }
