# Briareus for iPhone

A native SwiftUI client for [Briareus](https://github.com/nadinyamaui/briareus), using the versioned mobile API introduced in [PR #59](https://github.com/nadinyamaui/briareus/pull/59) and extended in [PR #62](https://github.com/nadinyamaui/briareus/pull/62). Requires iOS 17 or later. No third-party app dependencies.

## What it does

- Connects to your HTTPS dashboard with a per-device token stored in Keychain.
- Lists permitted projects and conversations, with search and status updates.
- Shows incremental transcripts, agent questions, tool activity, queued messages and costs.
- Starts conversations on a chosen branch, provider, model and effort (or the project default), sends follow-ups, turns the review loop on or off, completes held findings triage, renames, stops, closes, reopens and deletes sessions when the token permits it.
- Shows the project board as the dashboard does: open pull requests with their labels, whether they conflict with their base, the state of their checks, author, assignees, reviewers, linked issues and stack, narrowed by author, reviewer or label.
- Opens a pull request on its description, file changes with diffs, checks, reviews, commits, the issues it closes, findings and the conversations already run on it; records fix, optional or dismiss decisions on findings, and merges when the server offers `merge_pull`, saying first what stands in the way.
- Starts the board's errands on a pull request using the server-configured runtime: run, code review, solve conflicts, fix failing checks, implement feedback, feedback in your own words, test sheet, QA, PR body and delete my comments, with the one its state asks for marked as suggested.
- Lists the repository's open issues, sub-issues nested under their epic, with the pull requests answering each, and starts a session on an issue.
- Records voice notes and has the server transcribe them into the message box, in whichever language was spoken. On a server that cannot transcribe, the microphone says what the server is missing.
- Revokes its token remotely or forgets the local connection.

Read-only connections hide write controls. A capability catalog keeps unsupported operations unavailable. Projects, conversations, transcripts and pull requests are saved on the phone, so a screen opens on what it last showed and then asks the server only for what changed; a saved transcript resumes from its last event, and pulling down reads it again in full. Backgrounding pauses polling and covers the app switcher snapshot.

## Open and run

1. Clone this repository on a Mac with Xcode 16 or later.
2. Open `Briareus.xcodeproj` and select the **Briareus** scheme.
3. Select an iPhone simulator and Run. The simulator needs no signing team.
4. For a real iPhone, select your Apple development team under **Signing & Capabilities** and use a bundle identifier registered to that team; select the connected phone and Run.
5. To distribute through TestFlight, use an Apple Developer Program team, register the app in App Store Connect, then **Product → Archive → Distribute App**. Signing identities and provisioning profiles are intentionally not in this repository.

The checked-in project works without a generator installation. After adding source files, run `python3 scripts/generate-project.py` and commit the updated project. The generator resets generated build settings, so make persistent bundle/team changes there too.

## Connect to your server

Deploy Briareus PR #62 or later (PR #59 works without the model picker and in-app diffs; voice notes need [PR #66](https://github.com/nadinyamaui/briareus/pull/66) and the server's `OPENAI_TRANSCRIBE_API_KEY` and `OPENAI_TRANSCRIBE_MODEL`), enable dashboard password login, then create a device token in **Settings → Mobile devices**. Choose permitted projects and Read only or Manage. Paste the public HTTPS server address (or its `/api/mobile/v1` URL) and one-time token into the app.

If Cloudflare Access protects the dashboard, follow the server's [mobile deployment guide](https://github.com/nadinyamaui/briareus/blob/main/docs/mobile-api.md). Only `/api/mobile/v1` and `/api/mobile/v1/*` receive the mobile exception. A redirect or HTML page in the app means the mobile endpoint is still intercepted or misconfigured. The app does not change server deployment or Cloudflare settings.

A revoked/expired token returns to pairing. Create a replacement in web Settings. Forgetting removes local credentials and saved conversations only; it does not revoke a server token or stop existing agents.

## Validation

```sh
swift test
xcodebuild -project Briareus.xcodeproj -scheme Briareus \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Briareus.xcodeproj -scheme Briareus \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO test
```

Choose an installed simulator for the last command (`xcrun simctl list devices available`). The GitHub Actions workflow selects one automatically, runs the core tests, builds both simulator and physical-iPhone targets, runs the pairing UI test, and uploads a simulator `.app` zip and test results. The simulator artifact is not an installable iPhone IPA. Core tests run on macOS or Linux with Swift 5.9+; SwiftUI and signing require Xcode on macOS.

Tests exercise the saved-response cache, origin validation, credential headers, operation bodies, redirect rejection, non-JSON responses, expiry, rate limiting, write timeouts without retry, revocation, response compatibility, transcript cursor/deduplication, runtime selection, pull request file paging, diff line numbering, board rows, filters, errands and issue nesting. The simulator test verifies pairing and HTTP rejection without a live server or a real token.

Manual acceptance with a deployed test project:

- Pair with a Read-only token; verify only its projects appear and mutation controls are absent.
- Pair with Manage, start a conversation, send a follow-up and check the dashboard sees it once.
- Background/foreground and leave/reopen the conversation; verify it opens at once on the saved transcript, then shows incremental updates and no duplicate events.
- Quit and relaunch the app; verify projects appear before the server answers and refresh afterwards.
- Test a question, tools, queued follow-up, stop, rename, close and reopen; confirm before deleting a disposable session.
- Open the pull requests and compare labels, conflicts, checks and filters against the dashboard's board; open a PR and compare checks/reviews/findings. The actions start paid agents and may write to GitHub.
- Revoke the token in web Settings during polling and verify pairing appears; also test self-revocation and local-only forgetting.
- Record a voice note in a conversation and in a new one; verify its text lands at the end of the box, that discarding sends nothing, that a Read-only token shows no microphone, and that a server without transcription explains what it is missing when the microphone is pressed.
- Lose networking during a write; refresh/check the outcome before submitting it again.
- Test Dynamic Type, VoiceOver, landscape, dark mode and a physical iPhone.

## Boundaries

This first client covers the native mobile API's core workflow. The API does not expose attachment upload/download, APNs push notifications, workspace previews, provider management or full web composer modes. Diffs GitHub does not return (binary or very large files) open on GitHub instead. Review, QA and the board's other actions always use the runtime configured on the server. A pull request's labels and conflicts come from the board, which lists open pull requests only, so a merged or closed one shows neither. Run prepares and serves the workspace, but its preview link keeps the browser's protection and does not open from the app. Starting an epic, which picks an orchestrator's and its workers' models, remains in the web dashboard.

HTTPS is required. The native transport has no cookies or HTTP cache, refuses all redirects, never embeds a shared token, and never automatically retries a write. Credentials use [Keychain's device-only, when-unlocked protection](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly), scoped by canonical server origin. The app follows Apple's [URLSession redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)) behavior. Only the server origin is saved in UserDefaults; the privacy manifest declares that use. Saved responses live in the app’s Caches directory with [complete file protection](https://developer.apple.com/documentation/foundation/fileprotectiontype/complete), are left out of backups, and are erased when the connection is forgotten, revoked, expired or replaced by another device token; entries untouched for 30 days are dropped. No analytics or third-party tracking SDK is included. Your configured server processes conversations under its own policies.
