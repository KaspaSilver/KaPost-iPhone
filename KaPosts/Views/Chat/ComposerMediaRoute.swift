import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum ComposerMediaLimits {
    /// Ceiling for a voice note uploaded to Nextcloud, everywhere in the app (1:1, groups and
    /// public chats). On-chain voice notes are payload-bound: ~25 s in 1:1, ~10 s elsewhere.
    static let nextcloudVoiceSeconds: TimeInterval = 300
}

/// A video picked from the photo library ("Send Photo or Video via Nextcloud"), copied to a temp
/// file the caller owns - the Nextcloud video send deletes it once uploaded.
struct PickedMovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("kachat-picked-video-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovieFile(url: copy)
        }
    }
}

extension PhotosPickerItem {
    /// The library item is a video rather than a still.
    var isMovie: Bool {
        supportedContentTypes.contains { $0.conforms(to: .movie) }
    }
}
