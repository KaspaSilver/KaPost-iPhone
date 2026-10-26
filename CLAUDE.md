# CLAUDE.md

Guidance for Claude Code in this repository.

## What KaPosts is

KaPosts is a standalone iOS app for KaPosts (the on-chain social feed) and Public Chats, split out
of KaChat so KaChat can stay focused on 1:1 and group chats. One account = one Kaspa address,
used to sign and pay for every post, reply, like, follow and room message.

The source started as a copy of KaChat-iPhone (`KaspaSilver/KaChat-iPhone`) at commit `8b31f71`
(2026-10-24). KaChat's other features are removed: 1:1 and group chat screens, groups, calls
(and WebRTC), Nextcloud, Chess, Swap, Cold Storage, Portfolio, the Address Book, Simple Mode,
KaChat's Profile tab and notification bell, Ecosystem/Bots/Stats, the welcome guide.

What is still KaChat-shaped underneath:
- `ChatService` keeps running the address's UTXO subscription and the transaction queue that
  posts, tips and room messages go through. Its 1:1 chat sync is switched off
  (`ChatService.oneToOneChatsEnabled = false`), but the code behind it (handshakes, contextual
  messages, `MessageStore`, `GroupStore`) is still there. `KaPostsTabView.onAppear` starts the
  subscription (`startPolling`).
- `.kachat` names: the services, the profile editor and the name screens
  (`Views/Ecosystem/KachatNamesLiveViews.swift`, `KachatMarketView.swift`) are kept; only the
  profile editor and the Wallet's Domains tab are reachable.
- `AppTab` / dock settings in `Models.swift` and `SettingsViewModel` are KaChat's dock model and
  unused here.
- Chats live in KaChat: a profile's "Chat in KaChat" opens `kachat://profile/<address>` (or its
  kachat.app page).

## Dock

`KaPosts/App/KaPostsTabView.swift` - five fixed tabs:

| Tab | View |
|---|---|
| Feed | `KaPostsPageView` (`Views/KaPosts/KaPostsView.swift`) |
| Public Chats | `PublicChatListView` (`Views/Chat/PublicChatListView.swift`); rooms hide the dock |
| Profile | `KaPostsView(rootMode: .myProfile)` - the KaPosts profile; Edit Profile opens `KaChatProfileEditorSheet` |
| Wallet | `ChattingAddressManageView(address:title: "Wallet")` - the one address's balance, history, UTXOs |
| Settings | `SettingsView`: Customization, Security, Connection, Notifications, KaPosts, Public Chats, Cache, Diagnostics, Open Source Licenses, View Seed Phrase, Delete Account |

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

Push registration and updates send `apns_topic` = the bundle id (`com.kachat.kaposts`,
`PushNotificationManager.apnsTopic`), like KaChat Wallet, so the shared push service sends
KaPosts pushes on KaPosts' topic. Without it Apple rejects them with `DeviceTokenNotForTopic`;
while the service doesn't honour it, KaPosts notifies through its in-app poller only.

Links: KaPosts opens `kaposts://` (same targets as `kachat://`). Shared links still read
`kachat://` / `https://kachat.app/post/...`, which open KaChat; for them to open KaPosts the
kachat.app apple-app-site-association needs KaPosts' app ID on `/post/*` and `/broadcast/*`, and
KaPosts an associated-domains entitlement.
