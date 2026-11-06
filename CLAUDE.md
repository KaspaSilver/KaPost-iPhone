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
| Public Chats | `PublicChatListView` (`Views/Chat/PublicChatListView.swift`); every default room is listed, the customize button (top left) switches rooms off, or all language rooms at once. Rows swipe (left: Delete, Mute, Pin; right: read state), and a pinned room moves into the circles row above the list, saved per account |
| Profile | `KaPostsView(rootMode: .myProfile)` - the KaPosts profile; Edit Profile opens `KaChatProfileEditorSheet`; Wallet pushes `KaPostWalletView`, KaChat's and KaPay's Wallet tab: the total (chatting plus spending), Send, Receive and More (Compound UTXOs, dimmed until the chatting address holds two or more coins, Request Payment, View Private Key, View Public Key, as in KaPlay), the Backup Hygiene card, then the chatting address's transaction history (`AddressTransactionRow`, shared with `ChattingAddressManageView`) |
| Notifications | `KaPostsNotificationsView`; the cog (top left) opens `NotificationsHubPage`, the notification settings (post notifications only - no wallet ones) |
| Settings | `SettingsView`, alphabetical like KaChat and KaPay: About (version, website, support email, Terms of Use, Privacy Policy, licenses), Account Name, Back Up Account (Complete Your Backup, View 12 or 24 Words, Back Up to NFC Card), Connection, Customization, Diagnostics, KaPost, Notifications, Security, Storage; then Delete Account (`DeleteAccountSheet`, the warning the opening screen's Delete also shows; `WalletManager.deleteCurrentAccount`), Log Out |

The dock stays in reach on every screen. Pushed screens (Wallet, notification settings, Public
Chats rooms, Settings pages) keep the real one. KaPosts' full-screen covers (threads, profiles,
the hamburger's screens, Post Activity) draw `KaPostsDockCopy` over themselves: the slide driver
(`KaPostsSlideDriverView`) puts it in the cover's presentation container, and a tap closes every
cover (`.kaPostsCloseCovers`) and selects the tab through `KaPostsDockRouter`. The composers and
the hamburger card have no dock.

Account setup follows KaPay: `ContentView` -> `OnboardingView` (create / import a seed) ->
`KaPostsTabView`. KaChat's welcome guide and dock wizard are not used. Create New Account makes an
account in one tap: 24 words, no passphrase, the next free default name
(`WalletManager.nextDefaultAccountName`). "Advanced: Create with a Passphrase" (`CreateWalletView`)
is the only other way. Import still takes 12 or 24 words. Creating never shows the seed phrase: an
account made here is owed a backup (`AccountBackupStatus`), and until the backup steps
(`AccountBackupView`) are finished `AccountBackupBanner` sits above every tab's title (red once the
account holds funds; `kaPostsFixedTitle` draws it, and the Feed above its own title; Receive shows only
the code and the address), and the Delete Account warning leads with Back Up Account; deleting is never blocked.
Imported and older accounts are never owed one. An import that answers Yes to the passphrase question
checks the first 50 addresses, picks the first with funds and lets you pick another; one without a
passphrase opens address #0. Importing or finishing the steps starts a six-month timer; when
it runs out the Wallet screen shows `BackupHygieneCard`, and `BackupHygieneView` asks for five random
words, then the passphrase if there is one. Every sign-in gets new tabs (`ContentView`'s
`signInSession`), opening on the Feed.

## NFC card backup

`Services/NFCCard.swift`, ported from KaChat-iPhone, whose CLAUDE.md has the design; the card commands and
backup format are `docs/PROTOCOL.md` in KaChat-NFC, so a card works across apps. It ships in production, like
KaChat and KaPay, and `NFCCard.isAvailable` is false on iPad. Settings > Back Up Account > Back Up to NFC Card (`NFCCardBackupView`) only
exists for an account with a BIP39 passphrase, which is never written to the card. Import Account > Restore from
NFC Card (`NFCCardRestoreView`). The App ID needs Near Field Communication Tag Reading on.

## Chatting address only

KaPost uses the chatting address and nothing else (owner's call, 2026-11-05): Send, tips and chat
payments leave from it (`WithdrawKaspaView.lockedSource` defaults to `.chatting`, and the tip sheet has
no From step), and Receive and Request Payment are paid to it. Spending addresses only count in the
Wallet total. Managing other addresses happens in KaChat and KaPay; `ChattingAddressManageView` and the
coin-control screens stay in the code but nothing opens them.

## Sends and account safety

Nothing that may have landed is offered again. A post, reply or thread whose send got no answer shows
"Not confirmed" (`DraftPost.Delivery.unconfirmed`) with no Retry, and `submitWithUtxoRetry` never retries
it; a room message stays pending, and a reaction is left as it is. An instant tip with an unknown outcome
shows a toast instead of the tip sheet. A node's "already accepted" answer counts only when it names the id
this device computed (`acceptedTransactionId(from:expected:)`). Instant default tips skip Face ID, so they
are capped at 10 KAS (`KaPostsSettingsView.instantTipLimitSompi`; a bigger one opens the tip sheet),
turning them on asks first, a fiat tip needs a price under ten minutes old (`KaspaPriceService.freshPrice`),
and a second tap while one is going out is ignored.

Same rules as KaChat and KaPay. Swiping up asks for the device lock first (`SwipeUpToSendScrollView`), which
covers Send Kaspa, a tip with a chosen amount and .kachat actions; default instant tips, posts and room
messages don't ask. Delete Account asks too. A submit with no answer ends in `SendOutcomeUnknownError`: the
screen says "Not confirmed" and offers only Done, since Try Again could pay twice. A node's answer must carry
the locally computed id. The words and passphrase are readable only while the phone is unlocked, so nothing
that runs in the background may need them (`allSpendingAddresses` reads the address cache). Keys left by an
earlier install are listed as saved accounts rather than opening. Third-party keyboards are refused, and the
privacy cover is its own window above sheets. A room message still pending from an earlier run is settled
once per room after its history loads (`settlePendingMessages`). People read "12 or 24 words", never "seed
phrase".

## Moderation (App Store guideline 1.2)

- Terms: `ContentView` shows `TermsAcceptanceView` until `KaPostTerms.currentVersion` is agreed to on
  this device; bump it when the text changes. Settings > About > Terms of Use shows them again.
- Report: a post's three dots, or in a room the message's long-press and the sender half sheet.
  `ContentReport` emails support; with no mail account it copies the report and says where to send it.
- Block: `KaPostsModerationStore` owns the list. It pushes the list to `PublicChatService.setBlockedSenders`,
  so a blocked account also leaves every room and its pushes stop. A room's own Hide User stays separate.
- Removal: no word filter, by the owner's choice (2026-11-02). The owner removes bad content by hand
  with the indexer's admin tool (`kachat-admin`), from reports or from seeing it.

## Identifiers

- Bundle ID `com.kachat.kaposts`, App Group `group.com.kachat.kaposts`, keychain group
  `$(AppIdentifierPrefix)com.kachat.kaposts`, URL scheme `kaposts`
- Team `RP4Z22SFSD` (the KaChat developer's Apple team; KaPosts ships under that account)
- Version: `KaPosts/Version.xcconfig` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`). KaPost's version
  number matches KaChat's, from 5.2.3 on.

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

Links to KaChat's own site (`home.kachat.app`, any page, `KaChatSiteLink`) preview by themselves: a
post draws the page's card (`LinkPreviewCardView`) in place of the link's text, and a room loads it
without the tap other links wait for. Other web links in posts stay plain text.

Links: KaPosts opens `kaposts://` (same targets as `kachat://`). Shared links still read
`kachat://` / `https://kachat.app/post/...`, which open KaChat; for them to open KaPosts the
kachat.app apple-app-site-association needs KaPosts' app ID on `/post/*` and `/broadcast/*`, and
KaPosts an associated-domains entitlement.
