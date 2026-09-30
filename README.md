# Briareus for iPhone, iPad, Mac and CarPlay

A native SwiftUI client for [Briareus](https://github.com/nadinyamaui/briareus), the dashboard for running coding agents against your projects. It talks to the server's versioned mobile API (`/api/mobile/v1`) and works with any Briareus server you can reach over HTTPS. Requires iOS 17 or macOS 14 or later. No third-party dependencies.

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Build and run](#build-and-run)
- [Deploy](#deploy)
  - [1. Prepare the server](#1-prepare-the-server)
  - [2. Make the app yours](#2-make-the-app-yours)
  - [3. Install on your own device](#3-install-on-your-own-device)
  - [4. Distribute through TestFlight or the App Store](#4-distribute-through-testflight-or-the-app-store)
  - [5. Pair the app with the server](#5-pair-the-app-with-the-server)
  - [Releasing an update](#releasing-an-update)
  - [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)
- [Validation](#validation)
- [Boundaries](#boundaries)
- [Security and privacy](#security-and-privacy)

## What it does

**Conversations**

- Lists the projects and conversations the device token permits, with search and status updates, and under each conversation its pull request, state and checks as the dashboard's badge shows them.
- Shows incremental transcripts with the time of each message, agent questions and queued messages. The tools, commands and git steps an agent runs are left out, as are workspace setup steps.
- Starts conversations on a chosen branch, provider, model and effort, or on the project default.
- Sends follow-ups, renames, stops, closes, reopens and deletes sessions.
- Turns the review loop on or off from inside a conversation.
- Keeps the review findings waiting for a decision in a section of their own in each project, as the dashboard does; the conversation they came from only says they are waiting.
- Records voice notes and has the server transcribe them into the message box, in whichever language was spoken. On a server that cannot transcribe, the microphone says what the server is missing.
- On an iPad, keeps the projects and conversations in a column on the left and the chosen conversation on the right, as the dashboard does. A window too narrow for both falls back to the phone's single column.
- On a Mac, runs as a Mac app built from the same sources: projects, a project's conversations and the chosen conversation each in a column of their own, which goes on updating while another app is in front.

**Project board**

- Shows open pull requests as the dashboard does: labels, whether they conflict with their base, the state of their checks, author, assignees, reviewers, linked issues and stack position, narrowed by author, reviewer or label.
- Opens a pull request on its description, file changes with diffs, checks, reviews, commits, the issues it closes, findings and the conversations already run on it.
- Records fix, optional or dismiss decisions on findings, and merges when the server offers it, saying first what stands in the way.
- Starts the board's errands on a pull request: run, code review, solve conflicts, fix failing checks, implement feedback, feedback in your own words, PR body and delete my comments. The one the pull request's state asks for is marked as suggested, and named on its row in the list.
- Lists the repository's open issues, sub-issues nested under their epic, with the pull requests answering each, and starts a session on an issue.

**In the car**

- Runs in CarPlay as a voice-based conversational app, on iOS 26.4 or later. A car has no keyboard, so what the agent is told is dictated; what was understood is shown and sent on a yes. The app listens and never speaks.
- Chooses a project, a conversation, a pull request or an issue from lists, and keeps the one chosen in hand on the voice screen.
- Starts a conversation from a dictated task, on a chosen branch, model and effort or on the project default. Sends follow-ups, answers an agent's question with one of the answers it offers, renames by dictation, stops, closes, reopens and deletes, removes queued messages and turns the review loop on or off.
- Completes a review round's triage, with a verdict per finding and a dictated note for the fix session.
- Shows a pull request's state, checks and reviews, records decisions on its findings, merges it, and starts the board's errands on it, feedback in your own words included. Starts a session on an issue.
- Asks before every paid or destructive action. Revokes the token or forgets the connection; pairing takes the phone.

**Connection**

- Pairs with a per-device token stored in Keychain, and revokes it remotely or forgets the local connection.
- Hides write controls on a Read-only token. A capability catalog read from the server keeps operations it does not offer unavailable, so the app adapts to older and newer servers.
- Saves projects, conversations, transcripts and pull requests on the device. A screen opens on what it last showed and then asks the server only for what changed; a saved transcript resumes from its last event, and pulling down reads it again in full.
- Pauses polling in the background and covers the app switcher snapshot.

## Requirements

| To | You need |
| --- | --- |
| Build and run in the simulator | A Mac with Xcode 16 or later |
| Run the Mac app | macOS 14 or later, and an Apple developer account signed in to Xcode |
| Install on your own device | A free or paid Apple developer account signed in to Xcode |
| Distribute through TestFlight or the App Store | [Apple Developer Program](https://developer.apple.com/programs/) membership |
| Use the app in a car | iOS 26.4 or later, and a build made with Xcode 26.4 or later and signed with the CarPlay entitlement Apple granted to your team |
| Use the app | A Briareus server with the mobile API, reachable over HTTPS, and a device token |
| Run the core tests only | Swift 5.9 or later, on macOS or Linux |

## Build and run

1. Clone this repository.
2. Open `Briareus.xcodeproj` and select the **Briareus** scheme.
3. Select an iPhone or iPad simulator and Run. The simulator needs no signing team.
4. For the Mac app, select **My Mac** and Run. It is sandboxed and keeps its token in the keychain under the team's access group, so it needs a signing team.

The checked-in project works without installing a generator. After adding or removing source files, regenerate it and commit the result:

```sh
python3 scripts/generate-project.py
```

The generator rewrites the project's build settings, so lasting changes to the bundle identifier, team or version belong in [scripts/generate-project.py](scripts/generate-project.py), not in Xcode's settings pane. CI fails when the checked-in project differs from what the generator produces.

## Deploy

A deployment has two halves: a Briareus server exposing the mobile API, and a signed build of this app on the device. Signing identities and provisioning profiles are intentionally not in this repository.

### 1. Prepare the server

1. Deploy a recent version of [Briareus](https://github.com/nadinyamaui/briareus) and publish it on an HTTPS hostname. Plain HTTP is refused by the app.
2. Enable dashboard password login (`npm run set-password`, then restart). The mobile API fails closed while login is off.
3. For voice notes, set `OPENAI_TRANSCRIBE_API_KEY` and `OPENAI_TRANSCRIBE_MODEL` on the server. Without them everything else works and the microphone explains what is missing.
4. If an access proxy such as Cloudflare Access protects the dashboard, exempt only `/api/mobile/v1` and `/api/mobile/v1/*` from its interactive login. The device token still guards every request. Do not exempt `/api/*`, `/settings`, `/login` or the whole hostname. The server's [mobile deployment guide](https://github.com/nadinyamaui/briareus/blob/main/docs/mobile-api.md) has the exact steps.
5. Check the endpoint from outside your network, without cookies:

   ```sh
   curl -i https://briareus.example.com/api/mobile/v1/
   ```

   A `401` with `application/json` means the endpoint is reachable and waiting for a token. A redirect or an HTML page means a proxy still intercepts the path.

The app never changes server or proxy settings.

### 2. Make the app yours

The project ships with its maintainers' bundle identifier and signing team. To sign it with your own account, edit these values in [scripts/generate-project.py](scripts/generate-project.py):

| Setting | Where | Set it to |
| --- | --- | --- |
| `PRODUCT_BUNDLE_IDENTIFIER` | app and UI test targets | An identifier you own, such as `com.example.briareus` and `com.example.briareus.uitests` |
| `DEVELOPMENT_TEAM` | app and UI test targets | Your ten-character Apple team ID |
| `MARKETING_VERSION` | app target | The version users see, such as `1.0` |
| `CURRENT_PROJECT_VERSION` | app target | The build number; raise it for every upload |

Then regenerate the project:

```sh
python3 scripts/generate-project.py
```

Your team ID is under **Membership details** in the [Apple developer account](https://developer.apple.com/account). For a one-off build you can instead override the values on the `xcodebuild` command line, as the examples below do, and leave the repository untouched.

### 3. Install on your own device

1. Connect the iPhone or iPad, unlock it and trust the Mac. Turn on **Settings → Privacy & Security → Developer Mode** on the device.
2. In Xcode, check that your team appears under **Signing & Capabilities** with automatic signing on.
3. Select the device as the destination and Run.

With a free Apple account the build expires after seven days and must be reinstalled; a paid membership lasts a year.

### 4. Distribute through TestFlight or the App Store

One-time setup:

1. Register the bundle identifier under **Certificates, Identifiers & Profiles** in the developer account, or let Xcode's automatic signing do it.
2. Create the app in [App Store Connect](https://appstoreconnect.apple.com) with the same bundle identifier.

From Xcode:

1. Select **Any iOS Device (arm64)** as the destination.
2. **Product → Archive**.
3. In the Organizer, **Distribute App → App Store Connect → Upload**.

From the command line, archive first:

```sh
xcodebuild -project Briareus.xcodeproj -scheme Briareus -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Briareus.xcarchive \
  DEVELOPMENT_TEAM=YOURTEAMID PRODUCT_BUNDLE_IDENTIFIER=com.example.briareus \
  CURRENT_PROJECT_VERSION=2 -allowProvisioningUpdates archive
```

Save this as `ExportOptions.plist`, outside the repository or left uncommitted:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>YOURTEAMID</string>
    <key>signingStyle</key><string>automatic</string>
</dict></plist>
```

Then export and upload:

```sh
xcodebuild -exportArchive -archivePath build/Briareus.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates
```

Set `destination` to `export` to get an `.ipa` in `build/export` instead of uploading. On a machine without a signed-in Xcode, such as a CI runner, add `-authenticationKeyPath`, `-authenticationKeyID` and `-authenticationKeyIssuerID` with an [App Store Connect API key](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api), kept in the runner's secrets.

Once the build finishes processing in App Store Connect:

- **TestFlight, internal**: add members of your team under **TestFlight → Internal Testing**. They get the build at once.
- **TestFlight, external**: create a group and submit the build for beta review. Reviewers need a server address and a device token to get past pairing; put them in the test information.
- **App Store**: fill in the listing and the privacy answers, then submit for review with the same demo access.

The app declares that it uses no non-exempt encryption (`ITSAppUsesNonExemptEncryption` is false), so uploads are not held for export compliance. It asks for the microphone only when a voice note is recorded.

### 5. Pair the app with the server

1. Sign in to the web dashboard and open **Settings → Mobile devices**.
2. Create a token: give the device a name, choose the projects it may see, **Read only** or **Manage**, and an expiry.
3. In the app, enter the public HTTPS server address (or its `/api/mobile/v1` URL) and the one-time token.

Issue one token per device. **Manage** permits paid agent starts, messages, GitHub changes and session deletion on the chosen projects; **Read only** permits none of them.

A revoked or expired token returns the app to pairing; create a replacement in the dashboard. Forgetting the connection removes local credentials and saved conversations only. It does not revoke the server token or stop running agents.

### CarPlay

CarPlay lists an app only when it is signed with a CarPlay entitlement, and Apple grants those to a team on request. Briareus asks for the one for voice-based conversational apps, `com.apple.developer.carplay-voice-based-conversation`.

1. Request the entitlement for your team at [developer.apple.com/contact/carplay](https://developer.apple.com/contact/carplay/), in the voice-based conversational category.
2. Once granted, add the CarPlay capability to the app's identifier under **Certificates, Identifiers & Profiles**.
3. Set `CARPLAY_ON_DEVICE = True` in [scripts/generate-project.py](scripts/generate-project.py) and regenerate the project. Builds for a device are then signed with [App/Briareus-CarPlay.entitlements](App/Briareus-CarPlay.entitlements).

Until then the flag stays off: a build that asks for an entitlement its team does not have fails to sign. Builds for the simulator always carry it, since the simulator asks for no grant.

Pair on the phone first. With transcription off on the server the car still works through its lists, but nothing can be dictated.

### Releasing an update

1. Raise `CURRENT_PROJECT_VERSION`, and `MARKETING_VERSION` for a user-visible release, in the generator.
2. Regenerate the project and commit it.
3. Run the [validation](#validation) commands.
4. Archive and upload as above.

App Store Connect rejects an upload whose build number it has already seen for that version.

### Troubleshooting

| Symptom | Cause |
| --- | --- |
| The app shows a redirect or an HTML page while pairing | An access proxy still intercepts `/api/mobile/v1`, or the address points at the wrong host |
| The address is rejected | It is not HTTPS |
| Pairing reappears during use | The token was revoked or expired, or the server's `AUTH_SECRET` was rotated |
| A project is missing | The token does not include it |
| Write controls are missing | The token is Read only, or the server does not offer that operation |
| Briareus is missing from the CarPlay home screen | The build is not signed with the CarPlay entitlement, or the phone runs an iOS before 26.4 |
| The car says to connect on the iPhone | The phone is not paired, or was restarted and not unlocked since |
| The microphone explains that transcription is off | The server lacks the transcription settings from step 1 |
| Signing fails with "no profiles found" | The bundle identifier belongs to another team; choose your own in step 2 |
| Xcode changes disappear after regenerating | They were made in Xcode instead of in the generator |

## Project layout

| Path | Contents |
| --- | --- |
| `App/` | SwiftUI screens, the CarPlay scene (`CarPlayScene`, `CarMenus`, `CarDictation`), the app store, Keychain access, voice notes, assets and the privacy manifest |
| `Core/` | The `BriareusCore` Swift package: API client, models, saved-response cache, board, diff and Markdown handling, and what a car's screen says. No UIKit or SwiftUI, so it builds and tests on macOS and Linux |
| `Tests/` | Core tests, run with `swift test` |
| `UITests/` | The pairing UI test, run in the simulator |
| `scripts/generate-project.py` | Generates `Briareus.xcodeproj` |
| `.github/workflows/ios.yml` | Continuous integration |

## Validation

```sh
swift test
```

```sh
xcodebuild -project Briareus.xcodeproj -scheme Briareus \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Briareus.xcodeproj -scheme Briareus \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

```sh
xcodebuild -project Briareus.xcodeproj -scheme Briareus \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO test
```

Choose an installed simulator for the last command (`xcrun simctl list devices available`).

The GitHub Actions workflow runs on every pull request and on pushes to `main`, as parallel jobs:

| Job | What it checks |
| --- | --- |
| Core tests | The checked-in project matches the generator, then `swift test` |
| Simulator build | Builds for the simulator and uploads a simulator `.app` zip |
| iPhone build | Builds the Release configuration for a physical device, unsigned |
| Mac build | Builds the Mac app, unsigned |
| Pairing UI test | Boots a simulator, runs the UI test and uploads the results |
| ios | Passes only when every job above passed; the one check to require in branch protection |

The simulator artifact is not an installable IPA, and the workflow neither signs nor uploads to App Store Connect.

Tests exercise the saved-response cache, origin validation, credential headers, operation bodies, redirect rejection, non-JSON responses, expiry, rate limiting, write timeouts without retry, revocation, response compatibility, transcript cursor and deduplication, runtime selection, pull request file paging, diff line numbering, board rows, filters, errands, issue nesting, and conversations and pull requests as a car's screen words them. The simulator test verifies pairing and HTTP rejection without a live server or a real token.

Manual acceptance with a deployed test project:

- Pair with a Read-only token; verify only its projects appear and mutation controls are absent.
- Pair with Manage, start a conversation, send a follow-up and check the dashboard sees it once.
- Open a conversation whose agent ran tools, commands and git steps; verify the transcript shows only the messages, questions and turn endings.
- Background/foreground and leave/reopen the conversation; verify it opens at once on the saved transcript, then shows incremental updates and no duplicate events.
- Quit and relaunch the app; verify projects appear before the server answers and refresh afterwards.
- Test a question, queued follow-up, stop, rename, close and reopen; confirm before deleting a disposable session.
- Open the pull requests and compare labels, conflicts, checks and filters against the dashboard's board; open a pull request and compare checks, reviews and findings. The actions start paid agents and may write to GitHub.
- Triage a round of findings from the project's Findings button and toggle the review loop from a conversation; verify the dashboard shows the same state.
- Revoke the token in the dashboard during polling and verify pairing appears; also test self-revocation and local-only forgetting.
- Record a voice note in a conversation and in a new one; verify its text lands at the end of the box, that discarding sends nothing, that a Read-only token shows no microphone, and that a server without transcription explains what it is missing when the microphone is pressed.
- Lose networking during a write; refresh and check the outcome before submitting it again.
- Test Dynamic Type, VoiceOver, landscape, dark mode, an iPad and a physical iPhone.
- In CarPlay, with the phone locked: choose a project and a conversation, dictate a message, answer no and yes when it is shown, and check the dashboard sees it once. Start a conversation, stop the agent, triage a round of findings, look at a pull request's checks, start an errand on it, check that music comes back after each dictation and that the app never speaks. Check that every list opens from the voice screen and that none goes deeper than two screens.
- On a Mac, choose a project and a conversation, resize the window, and check the conversation goes on updating with another app in front.

## Boundaries

The app covers what the mobile API exposes. The API does not offer attachment upload or download, push notifications, workspace previews, provider management or the web composer's full set of modes.

- In a car the agent's replies are not shown or read aloud: the screen says what a conversation is doing and what it asks, and the transcript, file changes and diffs stay on the phone. Search, and a branch that is not on the list, need the phone too, as does pairing.
- CarPlay lists show as many rows as the car allows, fewer while it moves; the rest are on the phone.
- Diffs GitHub does not return (binary or very large files) open on GitHub instead.
- Review and the board's other errands always use the runtime configured on the server.
- A pull request's labels and conflicts come from the board, which lists open pull requests only, so a merged or closed one shows neither.
- Run prepares and serves the workspace, but its preview link keeps the browser's protection and does not open from the app.
- Starting an epic, which picks an orchestrator's and its workers' models, remains in the web dashboard.

## Security and privacy

- HTTPS is required. The transport has no cookies or HTTP cache, [refuses all redirects](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)), and never automatically retries a write.
- No shared secret is built into the app. Each device holds its own token, in Keychain, scoped by canonical server origin and never leaving the device. On a Mac it is readable [while unlocked](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly); on an iPhone or iPad [from the first unlock after a restart](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly), since in a car the app runs with the phone locked.
- Only the server origin is saved in UserDefaults; the privacy manifest declares that use.
- Saved responses live in the app's Caches directory, [protected until the first unlock after a restart](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication) for the same reason, and are left out of backups. They are erased when the connection is forgotten, revoked, expired or replaced by another device token, and entries untouched for 30 days are dropped.
- Voice notes, and what is dictated in a car, are sent to your server for transcription and nowhere else by the app.
- No analytics or third-party tracking SDK is included. Your server processes conversations under its own policies.
