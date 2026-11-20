import Foundation

enum PublicChatChannelPresentationMode: Equatable {
    case inlineReplacement
    case navigationDestination
}

enum PublicChatNavigationPolicy {
    static func channelPresentationMode(isMacCatalyst: Bool) -> PublicChatChannelPresentationMode {
        isMacCatalyst ? .inlineReplacement : .navigationDestination
    }

    static var currentChannelPresentationMode: PublicChatChannelPresentationMode {
        channelPresentationMode(isMacCatalyst: isCurrentPlatformMacCatalyst)
    }

    private static var isCurrentPlatformMacCatalyst: Bool {
#if targetEnvironment(macCatalyst)
        return true
#else
        return false
#endif
    }
}
