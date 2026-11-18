import Foundation
import BackgroundTasks

/// The background fetch task KaChat registered for checking new messages. KaPost never
/// registers or schedules it; only `cancelBackgroundFetch` is left (Settings calls it).
@MainActor
final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    /// Background task identifier - must match Info.plist entry
    static let backgroundFetchTaskIdentifier = "com.kachat.kaposts.messageFetch"

    private init() {}

    /// Cancel any pending background fetch tasks
    func cancelBackgroundFetch() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundFetchTaskIdentifier)
        AppLog.log("%@", "[BackgroundTaskManager] Cancelled background fetch")
    }
}
