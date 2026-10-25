import SwiftUI
import AVFoundation
import AVFAudio
import PhotosUI
import CoreImage.CIFilterBuiltins
#if canImport(YbridOpus)
import YbridOpus
#endif

// Pieces KaChat's 1:1 chat screen shared with the public rooms, kept when that screen went.

/// Holds a weak reference to the raw `UIScrollView` backing a SwiftUI `ScrollView`, resolved via
/// `ScrollViewIntrospector` below - shared by `ChatDetailView` and `GroupChatDetailView` (each
/// keeps its own instance) since both need to drive the real scroll view directly during a
/// keyboard-focus transition, where `ScrollViewProxy.scrollTo` alone doesn't reliably land.
final class ScrollViewReference {
    weak var scrollView: UIScrollView? {
        didSet {
            guard scrollView !== oldValue else { return }
            observeContentSize()
        }
    }

    private var contentSizeObservation: NSKeyValueObservation?

    /// Keeps a chat pinned to its bottom while the content under it grows - a long message still
    /// laying out, a link preview or a photo arriving a moment after its row. Without it the row
    /// grew while the arrival's scroll animation was in flight: the animation landed short, then
    /// the list was shoved up in steps. Only when the reader was at the bottom just before the
    /// growth and isn't touching the list; anyone reading history above is never moved.
    private func observeContentSize() {
        contentSizeObservation = scrollView?.observe(\.contentSize, options: [.old, .new]) { scrollView, change in
            guard let old = change.oldValue, let new = change.newValue, new.height > old.height else { return }
            DispatchQueue.main.async {
                guard !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else { return }
                let insetBottom = scrollView.adjustedContentInset.bottom
                let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - insetBottom
                // measured against the size BEFORE the growth: was the reader at the end then?
                guard old.height - visibleBottom <= 24 else { return }
                let minOffsetY = -scrollView.adjustedContentInset.top
                let maxOffsetY = max(minOffsetY, scrollView.contentSize.height - scrollView.bounds.height + insetBottom)
                if maxOffsetY - scrollView.contentOffset.y > 0.5 {
                    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: maxOffsetY), animated: false)
                }
            }
        }
    }
}

struct ScrollViewIntrospector: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> ScrollViewIntrospectorView {
        let view = ScrollViewIntrospectorView()
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: ScrollViewIntrospectorView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolveIfNeeded()
    }
}

final class ScrollViewIntrospectorView: UIView {
    var onResolve: ((UIScrollView) -> Void)?
    private weak var resolvedScrollView: UIScrollView?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        resolveIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        resolveIfNeeded()
    }

    func resolveIfNeeded() {
        var candidate: UIView? = self
        while let view = candidate {
            if let scrollView = view as? UIScrollView {
                guard scrollView !== resolvedScrollView else { return }
                resolvedScrollView = scrollView
                DispatchQueue.main.async { [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    self.onResolve?(scrollView)
                }
                return
            }
            candidate = view.superview
        }
    }
}

#if canImport(YbridOpus) || OPUS_BRIDGE || OPUS_CATALYST
private enum WebMOpusEncodingError: LocalizedError {
    case invalidFormat(String)
    case conversionFailed(String)
    case audioReadFailed(String)
    case encoderInitFailed(Int32)
    case encoderSettingFailed(Int32)
    case encoderFailed(Int32)
    case noSamples

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let details):
            return "Unsupported audio format. \(details)"
        case .conversionFailed(let details):
            return "Audio conversion failed. \(details)"
        case .audioReadFailed(let details):
            return "Audio read failed. \(details)"
        case .encoderInitFailed(let code):
            return "Opus encoder init failed (\(code))."
        case .encoderSettingFailed(let code):
            return "Opus encoder setting failed (\(code))."
        case .encoderFailed(let code):
            return "Opus encoding failed (\(code))."
        case .noSamples:
            return "No audio samples to encode."
        }
    }
}

struct WebMOpusEncoder {
    static func encode(pcmURL: URL, outputURL: URL, bitrate: Int32, sampleRate: Double, maxBytes: Int? = nil) async throws {
        let pcmSamples = try await readFloatSamples(from: pcmURL, sampleRate: sampleRate)

        let totalFrames = pcmSamples.count
        guard totalFrames > 0 else {
            throw WebMOpusEncodingError.noSamples
        }

        var opusError: Int32 = 0
        guard let encoder = opus_encoder_create(Int32(sampleRate), 1, OPUS_APPLICATION_VOIP, &opusError) else {
            throw WebMOpusEncodingError.encoderInitFailed(opusError)
        }
        defer { opus_encoder_destroy(encoder) }

        let bitrateStatus = opus_encoder_set_bitrate(encoder, bitrate)
        if bitrateStatus != OPUS_OK {
            throw WebMOpusEncodingError.encoderSettingFailed(bitrateStatus)
        }
        _ = opus_encoder_set_vbr(encoder, 0)

        var lookahead: Int32 = 0
        _ = opus_encoder_get_lookahead(encoder, &lookahead)

        // Pre-skip must be in 48kHz samples per RFC 7845
        let preSkip48k = UInt16(clamping: Int(Double(lookahead) * 48000.0 / sampleRate))
        let opusHead = makeOpusHead(
            channels: 1,
            preSkip: preSkip48k,
            sampleRate: UInt32(sampleRate),
            outputGain: 0
        )

        let frameSize = max(1, Int(sampleRate / 50.0))
        var offset = 0
        var frameBuffer = [Float](repeating: 0, count: frameSize)
        var outputBuffer = [UInt8](repeating: 0, count: 1500)
        var packets: [Data] = []

        while offset < totalFrames {
            let remaining = totalFrames - offset
            let currentFrame = min(frameSize, remaining)
            frameBuffer.withUnsafeMutableBufferPointer { bufferPointer in
                if let base = bufferPointer.baseAddress {
                    memset(base, 0, frameSize * MemoryLayout<Float>.size)
                    pcmSamples.withUnsafeBufferPointer { samples in
                        if let source = samples.baseAddress?.advanced(by: offset) {
                            memcpy(base, source, currentFrame * MemoryLayout<Float>.size)
                        }
                    }
                }
            }

            let encodedSize = frameBuffer.withUnsafeBufferPointer { inputPointer in
                guard let baseAddress = inputPointer.baseAddress else {
                    return OPUS_BAD_ARG
                }
                return opus_encode_float(
                    encoder,
                    baseAddress,
                    Int32(frameSize),
                    &outputBuffer,
                    Int32(outputBuffer.count)
                )
            }
            if encodedSize < 0 {
                throw WebMOpusEncodingError.encoderFailed(encodedSize)
            }

            let packet = Data(outputBuffer[0..<Int(encodedSize)])
            packets.append(packet)
            offset += currentFrame
        }

        let durationSeconds = Double(totalFrames) / sampleRate
        let frameDurationMs = Int64((Double(frameSize) / sampleRate) * 1000.0)

        // The Info duration is what the packets actually hold - if the byte ceiling below ever
        // trims the tail, the header no longer claims the full recording.
        func keptDuration() -> Double {
            min(durationSeconds, Double(packets.count) * Double(frameDurationMs) / 1000.0)
        }
        var webmData = buildWebM(
            packets: packets,
            opusHead: opusHead,
            sampleRate: sampleRate,
            durationSeconds: keptDuration(),
            frameDurationMs: frameDurationMs
        )

        if let maxBytes = maxBytes {
            while webmData.count > maxBytes, packets.count > 1 {
                packets.removeLast()
                webmData = buildWebM(
                    packets: packets,
                    opusHead: opusHead,
                    sampleRate: sampleRate,
                    durationSeconds: keptDuration(),
                    frameDurationMs: frameDurationMs
                )
            }
        }

        try webmData.write(to: outputURL, options: .atomic)
    }

    private static func readFloatSamples(from url: URL, sampleRate: Double) async throws -> [Float] {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue == 0 {
            throw WebMOpusEncodingError.noSamples
        }

        let asset = AVAsset(url: url)
        let track: AVAssetTrack
        if #available(iOS 16.0, *) {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let first = tracks.first else {
                throw WebMOpusEncodingError.audioReadFailed("No audio track found.")
            }
            track = first
        } else {
            guard let first = asset.tracks(withMediaType: .audio).first else {
                throw WebMOpusEncodingError.audioReadFailed("No audio track found.")
            }
            track = first
        }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw WebMOpusEncodingError.audioReadFailed(error.localizedDescription)
        }
        guard reader.canAdd(output) else {
            throw WebMOpusEncodingError.audioReadFailed("Unable to add reader output.")
        }
        reader.add(output)
        guard reader.startReading() else {
            let details = reader.error?.localizedDescription ?? "Reader start failed."
            throw WebMOpusEncodingError.audioReadFailed(details)
        }

        var samples = [Float]()
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            if status != kCMBlockBufferNoErr || dataPointer == nil || length == 0 {
                continue
            }
            let count = length / MemoryLayout<Float>.size
            let floatPointer = dataPointer!.withMemoryRebound(to: Float.self, capacity: count) { $0 }
            samples.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: count))
        }
        if reader.status == .failed {
            let details = reader.error?.localizedDescription ?? "Reader failed."
            throw WebMOpusEncodingError.audioReadFailed(details)
        }
        return samples
    }

    private static func makeOpusHead(channels: UInt8, preSkip: UInt16, sampleRate: UInt32, outputGain: Int16) -> Data {
        var data = Data()
        data.append(contentsOf: Array("OpusHead".utf8))
        data.append(1)
        data.append(channels)
        data.append(contentsOf: le16(preSkip))
        data.append(contentsOf: le32(sampleRate))
        data.append(contentsOf: le16(UInt16(bitPattern: outputGain)))
        data.append(0)
        return data
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ]
    }

    private static func buildWebM(
        packets: [Data],
        opusHead: Data,
        sampleRate: Double,
        durationSeconds: Double,
        frameDurationMs: Int64
    ) -> Data {
        let ebmlHeader = makeEBMLHeader()
        let info = makeInfo(durationSeconds: durationSeconds)
        let tracks = makeTracks(opusHead: opusHead, sampleRate: sampleRate, channels: 1)
        let clusters = makeClusters(packets: packets, frameDurationMs: frameDurationMs)

        var segmentPayload = Data()
        segmentPayload.append(info)
        segmentPayload.append(tracks)
        segmentPayload.append(clusters)

        var segment = Data()
        segment.append(contentsOf: [0x18, 0x53, 0x80, 0x67])
        segment.append(encodeVint(UInt64(segmentPayload.count)))
        segment.append(segmentPayload)

        var output = Data()
        output.append(ebmlHeader)
        output.append(segment)
        return output
    }

    private static func makeEBMLHeader() -> Data {
        let elements = [
            makeElement(id: [0x42, 0x86], uint: 1),
            makeElement(id: [0x42, 0xF7], uint: 1),
            makeElement(id: [0x42, 0xF2], uint: 4),
            makeElement(id: [0x42, 0xF3], uint: 8),
            makeElement(id: [0x42, 0x82], string: "webm"),
            makeElement(id: [0x42, 0x87], uint: 4),
            makeElement(id: [0x42, 0x85], uint: 2)
        ]
        return makeElement(id: [0x1A, 0x45, 0xDF, 0xA3], payload: join(elements))
    }

    private static func makeInfo(durationSeconds: Double) -> Data {
        let timecodeScale: UInt64 = 1_000_000
        let durationMs = durationSeconds * 1000.0
        let elements = [
            makeElement(id: [0x2A, 0xD7, 0xB1], uint: timecodeScale),
            makeElement(id: [0x44, 0x89], float: durationMs),
            makeElement(id: [0x4D, 0x80], string: "kasia-ios"),
            makeElement(id: [0x57, 0x41], string: "kasia-ios")
        ]
        return makeElement(id: [0x15, 0x49, 0xA9, 0x66], payload: join(elements))
    }

    private static func makeTracks(opusHead: Data, sampleRate: Double, channels: UInt8) -> Data {
        let trackUID = UInt64(UInt32.random(in: UInt32.min...UInt32.max))
        let audio = makeElement(
            id: [0xE1],
            payload: join([
                makeElement(id: [0xB5], float: sampleRate),
                makeElement(id: [0x9F], uint: UInt64(channels))
            ])
        )

        let entryElements = [
            makeElement(id: [0xD7], uint: 1),
            makeElement(id: [0x73, 0xC5], uint: trackUID),
            makeElement(id: [0x83], uint: 2),
            makeElement(id: [0x86], string: "A_OPUS"),
            makeElement(id: [0x63, 0xA2], payload: opusHead),
            audio
        ]
        let entry = makeElement(id: [0xAE], payload: join(entryElements))
        return makeElement(id: [0x16, 0x54, 0xAE, 0x6B], payload: entry)
    }

    private static func join(_ parts: [Data]) -> Data {
        var data = Data()
        data.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts {
            data.append(part)
        }
        return data
    }

    /// About a second of packets per Cluster. One Cluster per 20 ms packet (the old layout) put
    /// ~15 bytes of container around each 15-byte Opus packet - ~1.5 KB/s, so the 31 KB cap
    /// silently cut a 25 s note at ~20.6 s (measured by the Android session). Grouped, a packet
    /// costs ~21 bytes: 25 s is ~26.7 KB. Every decoder in use reads several SimpleBlocks per
    /// Cluster (ours walks them all in order; Android/Desktop use standard WebM players).
    private static func makeClusters(packets: [Data], frameDurationMs: Int64) -> Data {
        var clusters = Data()
        let perCluster = max(1, Int(1000 / max(frameDurationMs, 1)))
        var index = 0
        while index < packets.count {
            let end = min(index + perCluster, packets.count)
            clusters.append(makeCluster(
                timecodeMs: Int64(index) * frameDurationMs,
                packets: packets[index..<end],
                frameDurationMs: frameDurationMs
            ))
            index = end
        }
        return clusters
    }

    private static func makeCluster(timecodeMs: Int64, packets: ArraySlice<Data>, frameDurationMs: Int64) -> Data {
        var payload = makeElement(id: [0xE7], uint: UInt64(timecodeMs))
        for (offset, packet) in packets.enumerated() {
            // relative to the Cluster's timecode: at most ~1 s, well inside the signed 16 bits
            payload.append(makeSimpleBlock(packet: packet, relativeMs: Int16(clamping: Int64(offset) * frameDurationMs)))
        }
        return makeElement(id: [0x1F, 0x43, 0xB6, 0x75], payload: payload)
    }

    private static func makeSimpleBlock(packet: Data, relativeMs: Int16) -> Data {
        var block = Data()
        block.append(0x81) // Track number 1 (VINT)
        block.append(contentsOf: be16(relativeMs)) // Relative timecode
        block.append(0x80) // Flags: keyframe (every Opus packet decodes on its own); no lacing
        block.append(packet)
        return makeElement(id: [0xA3], payload: block)
    }

    private static func makeElement(id: [UInt8], payload: Data) -> Data {
        var data = Data(id)
        data.append(encodeVint(UInt64(payload.count)))
        data.append(payload)
        return data
    }

    private static func makeElement(id: [UInt8], uint: UInt64) -> Data {
        makeElement(id: id, payload: encodeUnsigned(uint))
    }

    private static func makeElement(id: [UInt8], float: Double) -> Data {
        makeElement(id: id, payload: encodeFloat64(float))
    }

    private static func makeElement(id: [UInt8], string: String) -> Data {
        makeElement(id: id, payload: Data(string.utf8))
    }

    private static func encodeUnsigned(_ value: UInt64) -> Data {
        var bytes = [UInt8]()
        var temp = value
        repeat {
            bytes.insert(UInt8(temp & 0xFF), at: 0)
            temp >>= 8
        } while temp > 0
        return Data(bytes)
    }

    private static func encodeFloat64(_ value: Double) -> Data {
        let bits = value.bitPattern
        return Data([
            UInt8((bits >> 56) & 0xFF),
            UInt8((bits >> 48) & 0xFF),
            UInt8((bits >> 40) & 0xFF),
            UInt8((bits >> 32) & 0xFF),
            UInt8((bits >> 24) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8(bits & 0xFF)
        ])
    }

    private static func encodeVint(_ value: UInt64) -> Data {
        for length in 1...8 {
            let maxValue = (UInt64(1) << (7 * length)) - 1
            if value <= maxValue {
                var bytes = [UInt8](repeating: 0, count: length)
                var temp = value
                for i in 0..<length {
                    bytes[length - 1 - i] = UInt8(temp & 0xFF)
                    temp >>= 8
                }
                bytes[0] |= UInt8(1 << (8 - length))
                return Data(bytes)
            }
        }
        return unknownSize()
    }

    private static func unknownSize() -> Data {
        // EBML unknown size for length=8: 0x01 followed by 7x 0xFF.
        return Data([0x01] + Array(repeating: 0xFF, count: 7))
    }

    private static func be16(_ value: Int16) -> [UInt8] {
        let unsigned = UInt16(bitPattern: value)
        return [UInt8((unsigned >> 8) & 0xFF), UInt8(unsigned & 0xFF)]
    }
}
#else
private enum WebMOpusEncodingError: LocalizedError {
    case unsupportedPlatform

    var errorDescription: String? {
        "Audio encoding is not supported on this platform."
    }
}

struct WebMOpusEncoder {
    static func encode(pcmURL: URL, outputURL: URL, bitrate: Int32, sampleRate: Double, maxBytes: Int? = nil) async throws {
        throw WebMOpusEncodingError.unsupportedPlatform
    }
}
#endif




// MARK: - Shared Zero-Balance Funding Card

/// The zero-balance funding card - "fund your address" title, QR of the chatting
/// address, and the address itself with a copy affordance. Shared by
/// the 1:1 chat gate (this file), `GroupChatDetailView`, `PublicChatChannelView`, and KaPosts'
/// compose/reply interception (`ZeroBalanceFundingSheetView` below). Lives in this file rather
/// than its own to avoid pbxproj churn - see the repo's dangling-reference history.
struct ZeroBalanceFundingCardView: View {
    let address: String?
    /// The headline; nil = "Fund your address to start posting".
    var title: String? = nil
    /// Called after the address hits the pasteboard so the host can show its own toast; when
    /// nil (sheet contexts without a toast helper) the copy icon flips to a checkmark instead.
    var onCopied: ((String) -> Void)? = nil

    @State private var qrImage: UIImage?
    @State private var showCopiedCheckmark = false

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let title { Text(verbatim: title) } else { Text("Fund your address to start posting") }
            }
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .padding(8)
                    // Solid white behind the QR keeps it scannable in dark mode, where the
                    // glass material alone would leave the light modules too dim.
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
            }

            if let address {
                HStack(spacing: 8) {
                    Text(address)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        UIPasteboard.general.string = address
                        Haptics.success()
                        if let onCopied {
                            onCopied(address)
                        } else {
                            showCopiedCheckmark = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                showCopiedCheckmark = false
                            }
                        }
                    } label: {
                        Image(systemName: showCopiedCheckmark ? "checkmark" : "doc.on.doc")
                            .font(.scaled(size: 14, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(6)
                            .background(cardGlassBackground(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Copy address"))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(cardGlassBackground(cornerRadius: 20))
        .task(id: address) {
            guard let address else {
                qrImage = nil
                return
            }
            qrImage = Self.makeChattingAddressQRCode(from: address)
        }
    }

    /// Same glass treatment as the chat views' private `glassBackground` helpers.
    private func cardGlassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    /// Same CIFilter QR pattern as `ChatInfoView.makeQRCodeImage` - plain string payload, so
    /// any wallet/scanner reads the address directly.
    static func makeChattingAddressQRCode(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Sheet host for the funding card - used where the zero-balance gate intercepts an action
/// (KaPosts' new-post and reply entry points) instead of locking an always-visible composer.
/// Auto-dismisses the moment the chatting balance reaches `dismissAtSompi` (any KAS by default).
/// Also the "not enough funds" popup of a profile save.
struct ZeroBalanceFundingSheetView: View {
    var title: String? = nil
    var dismissAtSompi: UInt64 = 1
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var walletManager = WalletManager.shared

    var body: some View {
        ScrollView {
            ZeroBalanceFundingCardView(address: walletManager.currentWallet?.publicAddress, title: title)
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: walletManager.currentWallet?.balanceSompi) { balance in
            if let balance, balance >= dismissAtSompi { dismiss() }
        }
    }
}

/// The chat composer's text, held by reference so typing doesn't redraw the conversation (see
/// `ChatDetailView.messageText`).
final class ComposerTextBox {
    var text = ""
}

/// The preview a link-bearing message gets in the chat and group lists: never the link itself.
///
/// A raw URL in a list row is noise at best, and for Nextcloud media it was worse - the message
/// IS a public share link, so the row showed the address of someone's photo to anyone glancing
/// at the phone. Any message carrying an http(s) link previews as an attachment instead,
/// whatever else it says. Only web links count: a message that is a `kaspa:` address must keep
/// reading as one, and the detector would otherwise take that for a URL too.
enum LinkSafePreview {
    static let sentALink = "📎 Sent a link"

    /// Keyed the same way `formatPreview`'s cache is - the group row has no cache of its own and
    /// renders its preview on every pass, and a detector scan per pass is exactly the kind of
    /// per-row cost the chat list has been shedding.
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 512
        return cache
    }()

    static func apply(to text: String) -> String {
        let key = "\(text.utf8.count)|\(text.prefix(24))" as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let result = containsWebLink(text) ? sentALink : text
        cache.setObject(result as NSString, forKey: key)
        return result
    }

    private static func containsWebLink(_ text: String) -> Bool {
        guard let detector = SharedDetectors.link else { return false }
        let range = NSRange(text.startIndex..., in: text)
        var found = false
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            guard let scheme = match?.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            found = true
            stop.pointee = true
        }
        return found
    }
}
