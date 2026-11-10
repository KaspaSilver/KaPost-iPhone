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
| Profile | `KaPostsView(rootMode: .myProfile)` - the KaPosts profile; Edit Profile opens `KaChatProfileEditorSheet`; Log Out (red, beside Wallet); Wallet pushes `KaPostWalletView`, KaChat's and KaPay's Wallet tab: the total (chatting plus spending), Send, Receive and Request (Compound UTXOs and an address's keys are in Manage Addresses, under that address), the Backup Hygiene card, then `WalletAccountSections` |
| Notifications | `KaPostsNotificationsView`; the cog (top left) opens `NotificationsHubPage`, the notification settings (post notifications only - no wallet ones) |
| Settings | `SettingsView`, alphabetical like KaChat and KaPay: About (version, website, support email, Terms of Use, Privacy Policy, licenses), Account Name, Back Up Account (Complete Your Backup, View 12 or 24 Words, Back Up to NFC Card), Connection, Customization, Diagnostics, KaPost, Notifications, Security, Storage; then Delete Account. Log Out is on the Profile |

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
Imported and older accounts are never owed one. Import has no "which wallet" list (KaChat's change,
2026-11-10, kept in unison): name, 12 or 24, the words, then the passphrase question. No opens "Your
Account", Yes searches live as the passphrase is typed. Both run `WalletManager.findImportAccounts`: every
`WalletSourceFamily` (Standard 50 addresses, KDX and OneKey 20, Chainge 1) in one UTXO call, plus each
type's address #0 on Kaspa REST's transactions-count, so an emptied wallet still counts. The type holding
the most comes first (ties go to Standard) and its first address is picked; several found are listed, and
See Every Wallet Type adds each type's #0. Nothing found, a failure or the 12 s timeout means Standard #0
(the last two with Search Again). Importing or finishing the steps starts a six-month timer; when
it runs out the Wallet screen shows `BackupHygieneCard`, and `BackupHygieneView` asks for five random
words, then the passphrase if there is one. Every sign-in gets new tabs (`ContentView`'s
`signInSession`), opening on the Feed.

## NFC card backup

`Services/NFCCard.swift`, ported from KaChat-iPhone, whose CLAUDE.md has the design; the card commands and
backup format are `docs/PROTOCOL.md` in KaChat-NFC, so a card works across apps. It ships in production, like
KaChat and KaPay, and `NFCCard.isAvailable` is false on iPad. Settings > Back Up Account > Back Up to NFC Card (`NFCCardBackupView`) only
exists for an account with a BIP39 passphrase, which is never written to the card. Restore from NFC Card
(`NFCCardRestoreView`) sits at the bottom of Import Account's name screen. The App ID needs Near Field Communication Tag Reading on.

## Full wallet (KaPay's Wallet tab)

Every KaChat app has KaPay's full wallet (owner's call, 2026-11-07; it replaced "chatting address only"
from 2026-11-05). Profile > Wallet (`KaPostWalletView`) is KaPay's Wallet tab: the total split into
chatting and spending, Send, Receive and Request (Compound UTXOs and an address's keys are under that address in Manage
Addresses), Backup Hygiene when due, then `WalletAccountSections` (`Views/Wallet/WalletDomainViews.swift`):
the Manage Addresses (`ManageAddressesView`) and Chatting Address squares, Your Domains
(`KNSDomainsListView`, no Customize Profile: profiles are edited on KaPost's Profile) and Help. No transaction
history on this screen (owner's call, 2026-11-09). No Contacts (saved addresses): people use KaChat or KaPay for that (owner's call,
2026-11-07), so `AddressBookManager` isn't in KaPost.
Send has the From step (`WithdrawKaspaView.lockedSource` is nil unless an address's own Send opens it),
Receive shows a fresh address (`ReceiveKaspaQRView`), and Request Payment offers Fresh Address or Choose
an Address. Each single-address page has one options icon at the top right (`AddressOptionsButton`), opening
`AddressActionsSheet`: View Private Key, View Public Key (not for a quantum address, whose key stays hidden
until it spends) and View in Explorer. Ported from KaPay: keep these in unison with it, and port KaPay changes here. Spending
addresses number from #1 (`WalletManager.addressNumber`).

Tips: only one from the chatting address is a tip (KAPOSTS_INDEXER.md 5.11): it names the post,
counts on it and lists the tipper. The tip sheet opens on From, and KaPosts > Settings > Tips From
(`KaPostsTipSourceStore`, per account, `SendSource.defaultTip`) picks the instant tip's address and the
sheet's first choice. From another address a tip is private (owner's call, 2026-11-07):
`ChatService.sendPayment` drops the tip and sends a plain payment with the chat notice, so the author
gets it in your chat but it names no post, isn't counted and doesn't list you.

## Sends and account safety

Nothing that may have landed is offered again. A post, reply or thread whose send got no answer shows
"Not confirmed" (`DraftPost.Delivery.unconfirmed`) with no Retry, and `submitWithUtxoRetry` never retries
it; a room message takes the transaction's id and shows "Not confirmed" (`DeliveryStatus.unconfirmed`), which
its delivered copy turns into Sent, and a reaction is left as it is. An instant tip with an unknown outcome
shows a toast instead of the tip sheet. A payment put off until its coins confirm (`sendPayment` returning
nil) says "Waiting" (`SendDeferredError`), is not counted as a tip, and offers no Try Again. A node rejection
blocks the lost-answer check only when it is about the transaction itself (`isVerdictOnTransaction`):
"already in the mempool", orphan and spent-input answers may come from the copy whose answer was lost.

Coins: posts, likes, room messages, tips, Send and .kachat combining all draw from one ledger in
`ChatService` (`prepareMessageUtxos`, `unreservedUtxos`, `recordPlainSend`). What a send spent stays
reserved until it is in a block, so the next action never picks it again. An unknown outcome is deliberately
not held (`recordPlainSend` with a nil `txId`): a send made after "Not confirmed" picks the same coins, so only
one of the two can land.
`NodePoolService.submitTransaction` and `submitRpcTransaction(_:expectedTxId:)` reserve every submitted
transaction's inputs themselves (`ChatService.reserveOutpointKeys`), so KNS, .kachat and any new path are
covered too.
Fee estimates price the speed's extra in the shape the send builds, and Max stops at one transaction's
`maxInputsPerTransaction` coins (the tip sheet too). A failed fee estimate shows Try Again. Available,
Compound and Coin Control count only what a send may spend (`withdrawalSpendable`); Max at Fast or Priority
prices the extra on its own coins (`maxSendAmount`); a send rebuilt at the swipe that would pay more than the
Review showed stops with `SendFeeChangedError`. After a rejection, only a mempool or the built-in REST server
can call a send landed.

Accounts: every removal path clears both networks' stores and the spending-address data
(`removeSpendingData`); the Secure Enclave key goes only when no saved account or Keychain snapshot remains.
A failed key write puts the previous slot back. A record with no keys first tries its own snapshot before
the recovery screen, and import or Log Out clears a stale recovery. The passphrase search holds Import for
at most 12 s, with Skip and Search Again. The NFC PIN is typed twice. The Passcode Required alert has its own
window. A node's "already accepted" answer counts only when it names the id
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
once per room after its history loads (`settlePendingMessages`), as "Not confirmed" when its copy isn't
there. Held 5-second actions belong to the account they were made as (`KaPostsActionScheduler` drops them on
a switch), a thread chain stops if the account changes, and Reply is off on a post not on chain yet. People read "12 or 24 words", never "seed
phrase". `AppLog.log` shortens any Kaspa address to its last 8 characters, so logs
(and URLs in them) name no account.

.kachat names with the indexer down (`KachatNamesRegistry`, the same as KaChat): after 3 failures in a row
inside 120 s (`indexerOutageConfirmed`; an undecodable body doesn't count) the registry moves to its chain
copy (`fromIndexer`, `failOverToChain`), and a refresh goes back when it recovers. One missed status check
doesn't drop a working indexer; a wrong covenant id, `synced == false` or too much lag still do. A chain copy answers only if this session's walk reached the tip in the last 10 minutes
(`chainTipAt`, `readChainState`), so saved names keep showing and a name never reads as free from a stale or
partial copy. After a failover the indexer isn't asked for 60 s (`chainHoldUntil`). That covers the market reads and name gaps too. A failed read keeps what's on screen and
never marks a pending claim failed. `confirmOnChain` always checks the live UTXO, whatever the source: no record is
trusted to pay on its own. A commit from the chain copy forces a walk first (`lookupForCommit`), and a commit
resend reuses its own coins (`PendingRegistration.commitInputs`), so it can't land twice. A walk repeats until the tip
(`walkToTip`), the standby copy is walked every 30 minutes, and without an indexer a person's profile is
read from their own chain record (`chainProfile`).

## With the indexer down

The owner's rule across the iOS apps (2026-11-08): what relies on the indexer keeps working from the node
where it can, shows what it saved where it can't, and recovers by itself (`Services/KaPostsChainFallback.swift`).

- The indexer is the source whenever it's online. `KaPostsIndexerHealth`: every KaPost read and write reports.
  Confirmed down only after 3 failures in a row inside 120 s (a network failure that isn't cancelled or
  offline, 429 or 5xx), and any answer resets the count; a body that won't decode is an answer. Until then a
  failed request throws as before. One small request a minute looks for its return.
- Saved pages: `get` keeps each read's first page on disk (`KaPostsPageCache`, per account, cleared by Delete
  Account) and serves it only while confirmed down or with the phone offline.
- From the chain, first pages only: a person's posts and replies from Kaspa REST (`KaPostsChainPosts`), the
  Following feed from the people followed (the first 20), and new posts and replies from the block stream
  (`KaPostsLiveChainFeed`, only while down). Every one must pass its Schnorr signature, since a payload can
  name anyone. Nothing but the indexer lists every post, or who reacted to yours, so the global feed is the
  saved page plus what's new, and notifications are the saved page until it returns.
- The feed says so while it lasts. When the indexer answers, the feed, your profile and notifications reload,
  and every load gate is cleared, so it has the final word.
- Rooms: the same 3-failure rule per indexer (`unreachableIndexers`); while down a room stays on the block
  stream on cellular too. On recovery each backfilled room pages that indexer again from ten minutes before
  the outage (`rewindRoomsAfterOutage`, `deepBackfillFloor`). Older room history has no other source; saved
  rows stay.
- KaChat's 1:1 catch-up work doesn't apply: KaPost's 1:1 sync is off. Push can't work without the indexer.

## KaPost links in rooms

A post link (`kachat://kapost/<id>`, `kaposts://kapost/<id>` or `https://kachat.app/post/<id>`) in a
room or chat shows as a card (`KaChatInternalLinkCardView`) with the poster and the post's text, and a
tap opens the post in KaPost. The same card as KaChat's (owner's call, 2026-11-07): KNS or `.kachat`
name first, text on one line with control and direction marks gone, 300 characters, three lines,
"A post on KaPost" until it loads, "Shared a KaPost" in the room list (`LinkSafePreview`).
`KaPostLinkPreviewCache` reads the post from the chain (no reader key goes out) and asks again for a
post it couldn't find after 5 minutes.

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
while the service doesn't honour it, KaPosts gets no pushes. The in-app poller only updates the unseen count,
since `ChatService.localBannersEnabled` is off.

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
