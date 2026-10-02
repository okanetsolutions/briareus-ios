// Placeholders until the settings screens are ported. Delete this file once they are.
import SwiftUI

struct SettingsScreen: View { var body: some View { Text("Settings") } }
struct ProjectSettingsScreen: View { let row: JSON?; let defaults: JSON?; var body: some View { Text("Project") } }
struct ProviderSettingsScreen: View { let row: JSON?; let defaults: JSON?; var body: some View { Text("Provider") } }
struct DBServerSettingsScreen: View { let row: JSON?; let defaults: JSON?; var body: some View { Text("Database server") } }
struct SSHServerSettingsScreen: View { let row: JSON?; let defaults: JSON?; var body: some View { Text("SSH server") } }
