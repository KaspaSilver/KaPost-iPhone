# CLAUDE.md

Guidance for Claude Code in this repository.

## What KaPosts is

KaPosts is a standalone iOS app for KaPosts (the on-chain social feed) and Public Chats, split out
of KaChat so KaChat can stay focused on 1:1 and group chats. One account = one Kaspa address,
used to sign and pay for every post, reply, like, follow and room message.

The source started as a copy of KaChat-iPhone (`KaspaSilver/KaChat-iPhone`) at commit `8b31f71`
(2026-10-24). Most of `KaPosts/` is still that code, including features KaPosts never shows
(1:1 and group chats, Chess, Swap, Cold Storage, Portfolio, calls, Nextcloud). They are being
removed step by step; until then, change only what KaPosts uses.

## Dock

`KaPosts/App/KaPostsTabView.swift` - five fixed tabs:

| Tab | View |
|---|---|
| Feed | `KaPostsPageView` (`Views/KaPosts/KaPostsView.swift`) |
| Public Chats | `PublicChatListView` (`Views/Chat/PublicChatListView.swift`); rooms hide the dock |
| Profile | `KaPostsView(rootMode: .myProfile)` - the KaPosts profile; Edit Profile opens `KaChatProfileEditorSheet` |
| Wallet | `ChattingAddressManageView(address:title: "Wallet")` - the one address's balance, history, UTXOs |
| Settings | `SettingsView` (KaPosts and Public Chats rows replace KaChat's Chats / Chat History) |

Account setup is KaChat's, unchanged: `ContentView` -> `OnboardingView` (create / import a seed)
-> `KaPostsTabView`. KaChat's welcome guide and dock wizard are not used.

## Identifiers

- Bundle ID `com.kachat.kaposts`, App Group `group.com.kachat.kaposts`, keychain group
  `$(AppIdentifierPrefix)com.kachat.kaposts`, URL scheme `kaposts`
- Team `RP4Z22SFSD` (the KaChat developer's Apple team; KaPosts ships under that account)
- Version: `KaPosts/Version.xcconfig` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`)

## Build

The project uses a file-system-synchronized folder: every file under `KaPosts/` is in the app
target automatically (no pbxproj edits for new files). Exceptions (Info.plist, entitlements,
Version.xcconfig) are listed in the project's exception set.

```bash
xcodebuild -project KaPosts.xcodeproj -scheme KaPosts -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

Claude may build for the iOS Simulator and run it there. Device and App Store builds are the
owner's.

## Protocol and servers

Same as KaChat: payloads under `kchat:1:`, the KaChat indexer for KaPosts and Public Chats, the
node pool for transactions. The protocol and server docs live in KaChat-iPhone
(`KAPOSTS_INDEXER.md`, `PUBLIC_CHATS_INDEXER.md`, `PUSH_EXTENSIONS.md`, `TRANSLATION_SERVICE.md`).

Push notifications need the push service to accept the `com.kachat.kaposts` topic; until then
KaPosts notifies through its in-app poller only.
