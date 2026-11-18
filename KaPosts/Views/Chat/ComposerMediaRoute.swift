import Foundation

enum ComposerMediaLimits {
    /// Ceiling for a voice note uploaded to Nextcloud, everywhere in the app (1:1, groups and
    /// public chats). On-chain voice notes are payload-bound: ~25 s in 1:1, ~10 s elsewhere.
    static let nextcloudVoiceSeconds: TimeInterval = 300
}
