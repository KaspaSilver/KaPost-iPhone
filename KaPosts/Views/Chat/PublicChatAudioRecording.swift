import SwiftUI
import AVFoundation

/// Records a voice message for a public chat room with KaChat's on-chain voice settings
/// (`VoiceNotePolicy.publicChat`): 16 kbps CBR Opus in 60 ms frames, parts of at most 14.5 s,
/// up to 170 s (2:50), as long as 1 KAS of fees allows. A note of one part's length or less is
/// one untagged message; a longer one goes as tagged parts (`PublicChatService.sendPublicChatVoiceParts`).
@MainActor
final class PublicChatAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording
        case encoding
        case failed(String)
    }

    static let policy = VoiceNotePolicy.publicChat
    static var maxDuration: TimeInterval { policy.maxSeconds }
    private static let sampleRate: Double = 48_000

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var pcmURL: URL?

    func start() {
        guard state == .idle else { return }
        Task {
            let granted = await Self.requestPermission()
            guard granted else {
                state = .failed("Microphone access denied")
                return
            }
            beginRecording()
        }
    }

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func beginRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("broadcast_rec_\(UUID().uuidString).caf")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.record()

            self.recorder = recorder
            self.pcmURL = url
            self.elapsedSeconds = 0
            self.state = .recording
            startTimer()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder?.delegate = nil
        recorder = nil
        if let pcmURL {
            try? FileManager.default.removeItem(at: pcmURL)
        }
        pcmURL = nil
        state = .idle
        elapsedSeconds = 0
    }

    /// Stops recording and encodes it as the parts it goes as: at most 14.5 s each (one part,
    /// sent untagged, when it is that short), every part a complete WebM-Opus file. In order.
    /// Safe to call once `elapsedSeconds` reaches `maxDuration` too (the caller drives that cutoff).
    func stopAndEncodeParts() async throws -> [Data] {
        timer?.invalidate()
        timer = nil
        guard state == .recording, let recorder, let pcmURL else {
            throw KasiaError.networkError("Not recording")
        }
        state = .encoding
        recorder.stop()
        self.recorder = nil

        defer {
            try? FileManager.default.removeItem(at: pcmURL)
            self.pcmURL = nil
            if state == .encoding { state = .idle }
        }

        let urls = try await WebMOpusEncoder.encodeParts(
            pcmURL: pcmURL,
            outputDirectory: FileManager.default.temporaryDirectory,
            bitrate: VoiceNotePolicy.bitrate,
            sampleRate: Self.sampleRate,
            frameMs: VoiceNotePolicy.frameMs,
            partSeconds: Self.policy.partSeconds,
            maxParts: VoicePartTag.maxParts,
            maxBytes: Self.policy.maxBytes
        )
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        let parts = try urls.map { try Data(contentsOf: $0) }
        state = .idle
        return parts
    }

    /// Estimated WebM bytes of each part a recording of `seconds` goes as - the live fee.
    static func estimatedPartSizes(forDuration seconds: TimeInterval) -> [Int] {
        VoiceNoteLayout.partSizes(
            duration: min(seconds, maxDuration),
            partSeconds: policy.partSeconds,
            bitrate: VoiceNotePolicy.bitrate,
            frameMs: VoiceNotePolicy.frameMs,
            maxBytes: policy.maxBytes,
            sampleRate: sampleRate
        )
    }
}

/// Plays back a single voice message's decoded audio. One instance per message bubble (matches
/// Android's per-bubble `MediaPlayer` - no single "now playing" registry there either).
@MainActor
final class PublicChatAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var durationText = "0:00"

    private var player: AVAudioPlayer?
    private var decodedURL: URL?
    private var isPreparing = false

    func prepare(data: Data) {
        guard player == nil, !isPreparing else { return }
        isPreparing = true
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let decoded = try WebMOpusDecoder.decodeToPCMFile(data: data)
                let player = try AVAudioPlayer(contentsOf: decoded.url, fileTypeHint: AVFileType.caf.rawValue)
                await MainActor.run {
                    self.decodedURL = decoded.url
                    player.delegate = self
                    self.player = player
                    self.durationText = Self.formatDuration(player.duration)
                    self.isReady = true
                    self.isPreparing = false
                }
            } catch {
                AppLog.log("[PublicChatAudioPlayer] Failed to decode voice message: %@", error.localizedDescription)
                await MainActor.run { self.isPreparing = false }
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            if player.currentTime >= player.duration { player.currentTime = 0 }
            player.play()
            isPlaying = true
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.isFinite ? duration : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    deinit {
        if let decodedURL {
            try? FileManager.default.removeItem(at: decodedURL)
        }
    }
}

/// A compact play/pause + duration bubble for a voice message, styled to match the surrounding
/// text bubble's colors rather than Android's Material look.
struct PublicChatAudioBubble: View {
    let data: Data
    let isOwnMessage: Bool
    @StateObject private var player = PublicChatAudioPlayer()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.scaled(size: 26))
            }
            .disabled(!player.isReady)

            Text(player.durationText)
                .font(.caption)
                .monospacedDigit()

            if !player.isReady {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .foregroundColor(isOwnMessage ? .white : .primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 130, alignment: .leading)
        .task {
            player.prepare(data: data)
        }
    }
}

/// A long voice note's parts as the bubble plays them: the parts present, in index order.
struct PublicChatVoiceNoteInput: Equatable {
    /// How many parts the note has in all.
    let count: Int
    /// The parts present, in index order.
    let parts: [Data]

    var isComplete: Bool { parts.count >= count }
    /// Changes whenever a part arrives.
    var signature: String { parts.map { String($0.count) }.joined(separator: ",") }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.count == rhs.count && lhs.signature == rhs.signature
    }
}

/// Plays a long voice note as one recording: every part present is decoded and joined with no
/// gap (`WebMOpusDecoder.decodePartsToPCMFile`), so the length is the total and seeking
/// crosses parts. Parts that arrive later are picked up on the next Play.
@MainActor
final class PublicChatMultipartAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var durationText = "0:00"

    private var player: AVAudioPlayer?
    private var playbackURL: URL?
    private var playbackSignature: String?
    private var loadedSignature: String?
    private var duration: TimeInterval?
    private var progressTimer: Timer?
    /// A seek made before playback started: where the next Play begins.
    private var pendingSeekFraction: Double?

    /// The length of the parts present, again whenever a part arrives (unless playing).
    func preload(_ input: PublicChatVoiceNoteInput) {
        let signature = input.signature
        guard loadedSignature != signature, !isPlaying else { return }
        loadedSignature = signature
        isLoading = duration == nil
        let parts = input.parts
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = try? WebMOpusDecoder.decodePartsToPCMFile(parts: parts)
            if let url = decoded?.url { try? FileManager.default.removeItem(at: url) }
            await MainActor.run {
                guard let self, self.loadedSignature == signature else { return }
                if let decoded {
                    self.duration = decoded.duration
                    self.durationText = Self.formatted(decoded.duration)
                }
                self.isLoading = false
            }
        }
    }

    func toggle(_ input: PublicChatVoiceNoteInput) {
        if isPlaying {
            pause()
            return
        }
        // Paused on the same parts: carry on from there.
        if let player, playbackSignature == input.signature {
            if let fraction = pendingSeekFraction {
                player.currentTime = fraction * player.duration
                pendingSeekFraction = nil
            }
            start(player)
            return
        }
        let seek = pendingSeekFraction
        stop()
        pendingSeekFraction = seek
        isLoading = true
        let signature = input.signature
        let parts = input.parts
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = try? WebMOpusDecoder.decodePartsToPCMFile(parts: parts)
            await MainActor.run {
                guard let self else {
                    if let url = decoded?.url { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.isLoading = false
                guard let decoded else { return }
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback)
                    try AVAudioSession.sharedInstance().setActive(true)
                    let player = try AVAudioPlayer(contentsOf: decoded.url, fileTypeHint: AVFileType.caf.rawValue)
                    player.delegate = self
                    player.prepareToPlay()
                    self.playbackURL = decoded.url
                    self.playbackSignature = signature
                    self.player = player
                    self.duration = decoded.duration
                    if let fraction = self.pendingSeekFraction {
                        player.currentTime = fraction * player.duration
                        self.pendingSeekFraction = nil
                    }
                    self.start(player)
                } catch {
                    try? FileManager.default.removeItem(at: decoded.url)
                }
            }
        }
    }

    /// The scrubber: 0...1 across the whole note.
    func seek(toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        progress = clamped
        if let player {
            player.currentTime = clamped * player.duration
            durationText = Self.formatted(player.currentTime)
        } else {
            pendingSeekFraction = clamped
            if let duration { durationText = Self.formatted(clamped * duration) }
        }
    }

    private func start(_ player: AVAudioPlayer) {
        guard player.play() else {
            stop()
            return
        }
        isPlaying = true
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                if player.duration > 0 { self.progress = player.currentTime / player.duration }
                self.durationText = Self.formatted(player.currentTime)
            }
        }
    }

    private func pause() {
        player?.pause()
        progressTimer?.invalidate()
        progressTimer = nil
        isPlaying = false
    }

    private func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        playbackSignature = nil
        if let playbackURL {
            try? FileManager.default.removeItem(at: playbackURL)
            self.playbackURL = nil
        }
        isPlaying = false
        progress = 0
        pendingSeekFraction = nil
        if let duration { durationText = Self.formatted(duration) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }

    private static func formatted(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.isFinite ? duration : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    deinit {
        progressTimer?.invalidate()
        if let playbackURL {
            try? FileManager.default.removeItem(at: playbackURL)
        }
    }
}

/// The one bubble of a long voice note in a room: play, one scrubber across every part, the
/// total length, and while parts are still on their way, "Receiving… 7 of 12".
struct PublicChatVoiceNoteBubble: View {
    let input: PublicChatVoiceNoteInput
    let isOwnMessage: Bool
    @StateObject private var player = PublicChatMultipartAudioPlayer()

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle(input)
            } label: {
                if player.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.scaled(size: 26))
                }
            }
            .disabled(player.isLoading)

            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill((isOwnMessage ? Color.white : Color.secondary).opacity(0.3))
                        Capsule()
                            .fill(isOwnMessage ? Color.white : Color.accentColor)
                            .frame(width: geometry.size.width * player.progress)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard geometry.size.width > 0 else { return }
                                player.seek(toFraction: value.location.x / geometry.size.width)
                            }
                    )
                }
                .frame(height: 16)

                HStack(spacing: 6) {
                    Text(player.durationText)
                        .monospacedDigit()
                    if !input.isComplete {
                        Text("Receiving… \(input.parts.count) of \(input.count)")
                    }
                }
                .font(.caption)
            }
            .frame(minWidth: 120)
        }
        .foregroundColor(isOwnMessage ? .white : .primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 180, alignment: .leading)
        .onAppear { player.preload(input) }
        .onChange(of: input.signature) { _ in player.preload(input) }
    }
}
