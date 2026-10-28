# CLAUDE.md

Guidance for Claude Code in this repository.

## What KaPosts is

KaPosts is a standalone iOS app for KaPosts (the on-chain social feed) and Public Chats, split out
of KaChat so KaChat can stay focused on 1:1 and group chats. One account = one Kaspa address,
used to sign and pay for every post, reply, like, follow and room message.

The app is called **KaPost** wherever a person sees it: the home screen name
(`INFOPLIST_KEY_CFBundleDisplayName`), the permission prompts, every on-screen string and the
translations. The code, the project, the bundle ID, the `kaposts://` scheme and log tags keep
"KaPosts". Write "KaPost" in any new user-facing text.

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
  profile editor and the Wallet's Domains tab are reachable. `.kachat` is the only name service
  KaPosts reads: KNS (.kas), dotk (.k) and Kaspa Names (.kaspa) are switched off at their two
  entry points (`KNSService.isEnabled`, `NameServicesClient.otherServicesEnabled`), so the
  Domains tab, address fields, mentions and search see .kachat names only.
- `AppTab` / dock settings in `Models.swift` and `SettingsViewModel` are KaChat's dock model and
  unused here.
- Chats live in KaChat: a profile's "Chat in KaChat" opens `kachat://profile/<address>` (or its
  kachat.app page).

## Dock

`KaPosts/App/KaPostsTabView.swift` - five fixed tabs:

| Tab | View |
|---|---|
| Feed | `KaPostsPageView` (`Views/KaPosts/KaPostsView.swift`) |
| Public Chats | `PublicChatListView` (`Views/Chat/PublicChatListView.swift`); every default room is listed, the customize button (top left) switches rooms off, or all language rooms at once |
| Profile | `KaPostsView(rootMode: .myProfile)` - the KaPosts profile; Edit Profile opens `KaChatProfileEditorSheet`, Wallet pushes `ChattingAddressManageView` (balance, history, UTXOs) |
| Notifications | `KaPostsNotificationsView`; the cog (top left) opens `NotificationsHubPage`, the notification settings (post notifications only - no wallet ones) |
| Settings | `SettingsView`: Customization, Security, Connection, KaPosts, Notifications, Cache, Diagnostics, Open Source Licenses, View Seed Phrase, Log Out (deleting an account is on the opening screen's Saved Accounts) |

The dock stays in reach on every screen. Pushed screens (Wallet, notification settings, Public
Chats rooms, Settings pages) keep the real one. KaPosts' full-screen covers (threads, profiles,
the hamburger's screens, Post Activity) draw `KaPostsDockCopy` over themselves: the slide driver
(`KaPostsSlideDriverView`) puts it in the cover's presentation container, and a tap closes every
cover (`.kaPostsCloseCovers`) and selects the tab through `KaPostsDockRouter`. The composers and
the hamburger card have no dock.

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
xcodebuild -project KaPosts.xcodeproj -scheme KaPosts -destination 'platform=iOS Simulator,id=48DEB003-C22C-433B-80B8-8BE35D3019CC' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

KaPosts is tested on the **iPhone 17 Pro** simulator (iOS 26.5, UDID
`48DEB003-C22C-433B-80B8-8BE35D3019CC`). Claude may build for the iOS Simulator and run it there. Device and App Store builds are the
owner's.

## Protocol and servers

Same as KaChat: payloads under `kchat:1:`, the KaChat indexer for KaPosts and Public Chats, the
node pool for transactions. The mainnet default for the indexer, KaPosts, Public Chats, push and
translation is `https://indexer.kachat.app` (`AppSettings.defaultIndexerURL`). Its old name,
`kachat.duckdns.org`, is the same server; saved settings on it move over when they decode, and
the push manager sends no unregister for the rename. Links on the old name are no longer
recognized (only `kachat.app` and `kachat://`). Testnet has no indexer (`defaultTestnetIndexerURL`
is blank, so chat, push, KaPosts and Public Chats are off there); a saved `tnkachat.duckdns.org`
is cleared on decode. The protocol and server docs live in KaChat-iPhone
(`KAPOSTS_INDEXER.md`, `PUBLIC_CHATS_INDEXER.md`, `PUSH_EXTENSIONS.md`, `TRANSLATION_SERVICE.md`).

Push registration and updates send `apns_topic` = the bundle id (`com.kachat.kaposts`,
`PushNotificationManager.apnsTopic`), like KaChat Wallet, so the shared push service sends
KaPosts pushes on KaPosts' topic. Without it Apple rejects them with `DeviceTokenNotForTopic`;
while the service doesn't honour it, KaPosts notifies through its in-app poller only.

KaPosts has no notification service extension, so a chat push would show as a bare "New
message" banner. KaPosts registers with `watched_addresses: []` (main address only), and
`willPresent` drops any push whose thread isn't `kaposts` or `broadcast:<room>`. The push
service is asked to send KaPosts' topic only `kaposts` and `broadcast` pushes
(`docs/KAPOSTS_PUSH_KINDS.md` in the indexer repo).

Payment requests (`kachat://pay/...`, `https://kachat.app/pay/...`) are paid in KaPay, KaChat's
wallet app: a post shows the link as a card (`KaPostPaymentRequestCard`), and Pay opens
`kapay://pay/<same tail>` (`KaPayHandoff`). A chat-payment request (`chat=1`) is paid here, as an
encrypted chat payment KaPay can't make. Without KaPay installed, the App Store opens
(`KaPayHandoff.appStoreURL`: a search for KaPay until it is listed). KaChat follows the same rule.

Links: KaPosts opens `kaposts://` (same targets as `kachat://`). Shared links still read
`kachat://` / `https://kachat.app/post/...`, which open KaChat; for them to open KaPosts the
kachat.app apple-app-site-association needs KaPosts' app ID on `/post/*` and `/broadcast/*`, and
KaPosts an associated-domains entitlement.
