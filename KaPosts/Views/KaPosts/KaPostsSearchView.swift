import SwiftUI
import Combine

/// Search across KaPosts: posts by their text, and the people who wrote them.
///
/// CLIENT-SIDE, because the K indexer has no search endpoint - every one of its routes is a feed
/// or a lookup by id (see KAPOSTS_INDEXER.md). So this pages the global feed and filters what
/// comes back, which has one honest consequence worth stating in the UI rather than hiding: it
/// searches as far back as it has paged, not the whole chain. The "Keep looking" button is how
/// the user asks it to go further, and it says how far it has got.
///
/// People are derived from the authors of the posts it scans, which is what makes "only people
/// who have posted at least once" true by construction rather than by a filter that could be
/// wrong: an address is only ever offered here because a post of theirs was read.
struct KaPostsSearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case posts = "Posts"
        case people = "People"
        var id: String { rawValue }
    }

    /// Opening a result: the parent owns navigation, so it is handed back rather than pushed.
    /// A TXID rather than the post itself - the parent resolves it through the same path a
    /// shared link takes, which knows how to find a post that is not in the loaded feed. Every
    /// row here came from the indexer, so it always has one.
    var onOpenPost: (String) -> Void
    /// The author's address and K pubkey (from the posts scanned; the profile needs the pubkey
    /// to load their posts, replies and follower counts, and to follow on chain).
    var onOpenProfile: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var knsService = KNSService.shared
    /// `.kachat` names (`KachatLive.identityName`) land on their own.
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared
    @ObservedObject private var moderationStore = KaPostsModerationStore.shared

    @State private var query = ""
    @State private var scope: Scope = .posts
    /// Everything paged so far this session, newest first, deduped by id.
    @State private var scanned: [KaPostsView.DraftPost] = []
    /// Each scanned post's text, lowercased once when it is read rather than on every search.
    @State private var lowercasedText: [UUID: String] = [:]
    /// The results for the current query, scope and scan, worked out once when one of them
    /// changes (`recomputeResults`) instead of on every body pass.
    @State private var matchingPosts: [KaPostsView.DraftPost] = []
    @State private var matchingPeople: [Person] = []
    @State private var recomputeScheduled = false
    @State private var cursor: String?
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var loadFailed = false

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Results

    struct Person {
        let address: String
        let postCount: Int
    }

    /// Fills the active scope's results for the current query. One pass: each author's name
    /// is looked up once, not once per post and again inside the sort.
    private func recomputeResults() {
        let q = trimmedQuery
        guard !q.isEmpty else {
            if !matchingPosts.isEmpty { matchingPosts = [] }
            if !matchingPeople.isEmpty { matchingPeople = [] }
            return
        }
        var names: [String: String] = [:]
        func name(_ address: String) -> String {
            if let cached = names[address] { return cached }
            let value = displayName(for: address)
            names[address] = value
            return value
        }
        var nameHits: [String: Bool] = [:]
        func nameHit(_ address: String) -> Bool {
            if let cached = nameHits[address] { return cached }
            let value = nameMatches(address, query: q, shown: name(address))
            nameHits[address] = value
            return value
        }
        switch scope {
        case .posts:
            matchingPosts = scanned.filter { post in
                guard !moderationStore.isHidden(post.posterAddress) else { return false }
                let text = lowercasedText[post.id] ?? post.text.lowercased()
                if text.contains(q) { return true }
                // A post also matches on WHO wrote it, so searching a name finds their posts
                // without having to switch tabs to find them first.
                return nameHit(post.posterAddress)
            }
        case .people:
            // One row per author, with how many of their scanned posts there are - so the list
            // is ordered by who is actually active rather than by whoever posted most recently.
            var counts: [String: Int] = [:]
            for post in scanned where !post.posterAddress.isEmpty {
                guard !moderationStore.isHidden(post.posterAddress) else { continue }
                counts[post.posterAddress, default: 0] += 1
            }
            matchingPeople = counts
                .filter { address, _ in nameHit(address) || address.lowercased().contains(q) }
                .map { Person(address: $0.key, postCount: $0.value) }
                .sorted { lhs, rhs in
                    lhs.postCount == rhs.postCount
                        ? name(lhs.address) < name(rhs.address)
                        : lhs.postCount > rhs.postCount
                }
        }
    }

    /// Whether the query finds this author by name. A `.kachat` name matches in either form,
    /// whatever Show .kachat Endings shows: its label ("alice") or written out ("alice.kachat").
    /// The ending on its own doesn't count, or "kachat" would find every named author.
    private func nameMatches(_ address: String, query: String, shown: String) -> Bool {
        guard let rawLabel = kachatRegistry.cachedIdentity(for: address)?.label, !rawLabel.isEmpty else {
            return shown.lowercased().contains(query)
        }
        let label = rawLabel.lowercased()
        if label.contains(query) { return true }
        if query.contains("."), "\(label).kachat".contains(query) { return true }
        // A name given to the contact on this device is shown in its place, and searched too.
        guard shown != KachatNameLabel.display(rawLabel) else { return false }
        return shown.lowercased().contains(query)
    }

    /// Names, pictures and the hidden list landing change what matches. Built once, so every
    /// body pass hands `onReceive` the same publisher.
    private static let identityChanges: AnyPublisher<Void, Never> = Publishers.Merge3(
        KachatNamesRegistry.shared.objectWillChange.map { _ in () },
        KNSService.shared.objectWillChange.map { _ in () },
        KaPostsModerationStore.shared.objectWillChange.map { _ in () }
    )
    .eraseToAnyPublisher()

    /// A burst of names landing is one pass, a moment after the last change has been stored
    /// (`objectWillChange` fires before it is).
    private func scheduleRecompute() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            recomputeScheduled = false
            recomputeResults()
        }
    }

    /// An author's K pubkey, from any of their scanned posts.
    private func pubkey(for address: String) -> String? {
        scanned.first { $0.posterAddress == address && $0.posterPubkey?.isEmpty == false }?.posterPubkey
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                if trimmedQuery.isEmpty {
                    promptState
                } else if scope == .posts {
                    postResults
                } else {
                    peopleResults
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Posts and people")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // One page up front so the first search has something to answer with.
                if scanned.isEmpty { await loadMore() }
            }
            .onChange(of: trimmedQuery) { _ in recomputeResults() }
            .onChange(of: scope) { _ in recomputeResults() }
            .onChange(of: scanned.count) { _ in recomputeResults() }
            .onReceive(Self.identityChanges) { _ in scheduleRecompute() }
        }
    }

    // MARK: - States

    private var promptState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.scaled(size: 40))
                .foregroundColor(.secondary)
            Text("Search KaPost")
                .font(.headline)
            Text("Find posts by what they say, and people by their name or domain. Only people who have posted appear.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    @ViewBuilder
    private var postResults: some View {
        if matchingPosts.isEmpty && !isLoading {
            emptyResults
        } else {
            List {
                ForEach(matchingPosts) { post in
                    Button {
                        guard let txId = post.remoteId else { return }
                        onOpenPost(txId)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName(for: post.posterAddress))
                                .font(.subheadline.weight(.semibold))
                            Text(post.text)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                            Text(post.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                depthFooter
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var peopleResults: some View {
        if matchingPeople.isEmpty && !isLoading {
            emptyResults
        } else {
            List {
                ForEach(matchingPeople, id: \.address) { person in
                    Button {
                        onOpenProfile(person.address, pubkey(for: person.address))
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            KNSAvatarView(
                                avatarURLString: knsService.profileCache[person.address]?.avatarURL,
                                fallbackText: displayName(for: person.address),
                                size: 36,
                                contactAddress: person.address
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(for: person.address))
                                    .font(.subheadline.weight(.semibold))
                                Text(person.postCount == 1 ? "1 post found" : "\(person.postCount) posts found")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                depthFooter
            }
            .listStyle(.plain)
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("Nothing found yet")
                .font(.headline)
            Text(hasMore
                 ? "Searched the most recent \(scanned.count) posts. Older ones have not been read yet."
                 : "Searched every post available.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if hasMore {
                Button {
                    Task { await loadMore() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Keep looking")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }
            Spacer()
        }
    }

    /// Says how deep the search has gone, and offers to go deeper. Shown under the results
    /// rather than only when empty: a handful of hits does not mean there are no more.
    @ViewBuilder
    private var depthFooter: some View {
        if hasMore {
            Button {
                Task { await loadMore() }
            } label: {
                HStack(spacing: 8) {
                    if isLoading { ProgressView() }
                    Text(isLoading ? "Reading older posts" : "Search older posts")
                        .font(.footnote.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("\(scanned.count) read")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        } else if loadFailed {
            Text("Could not read any further just now.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Paging

    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            var seen = Set(scanned.map(\.id))
            let batch = try await KaPostsPaginator.collect(
                from: cursor,
                fetch: { before, limit in
                    let page = try await KaPostsAPIClient.shared.fetchGlobalFeed(limit: limit, before: before)
                    return (page.posts, page.pagination)
                },
                keep: { posts in
                    posts.compactMap { post -> KaPostsView.DraftPost? in
                        guard let mapped = KaPostsView.mapRemotePost(post),
                              seen.insert(mapped.id).inserted else { return nil }
                        return mapped
                    }
                }
            )
            for item in batch.items { lowercasedText[item.id] = item.text.lowercased() }
            scanned.append(contentsOf: batch.items)
            cursor = batch.cursor
            hasMore = batch.hasMore
            // Warm the names for whoever just arrived, so People rows are not a wall of
            // shortened addresses. Bounded and debounced inside KNSService.
            let addresses = Array(Set(batch.items.map(\.posterAddress).filter { !$0.isEmpty }))
            if !addresses.isEmpty {
                await knsService.refreshProfilesIfNeeded(for: addresses)
            }
        } catch {
            loadFailed = true
        }
    }

    private func displayName(for address: String) -> String {
        guard !address.isEmpty else { return "Unknown" }
        if let assigned = ContactsManager.shared.getContact(byAddress: address)?.assignedName {
            return KaPostsView.displayKasName(assigned)
        }
        // Who they are: their .kachat name (a .kas domain isn't identity since 5.2).
        if let name = KachatLive.identityName(address) { return name }
        if !KachatNamesService.isEnabled, let domain = knsService.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.displayKasName(domain)
        }
        if !KachatNamesService.isEnabled, let domain = knsService.identityInfo(for: address)?.primaryDomain,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.displayKasName(domain)
        }
        return Contact.generateDefaultAlias(from: address)
    }
}
