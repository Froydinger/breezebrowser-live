import Cocoa
import UserNotifications

enum BreezeSoundEvent: Hashable {
    case newTab
    case notification
    case downloadStarted
    case downloadComplete
    case downloadFailed
    case error
    case splitOpened
    case splitClosed
    case sitePinned

    var settingKey: String {
        switch self {
        case .newTab: return "newTabSounds"
        case .notification: return "notificationSounds"
        case .downloadStarted: return "downloadStartedSounds"
        case .downloadComplete: return "downloadCompleteSounds"
        case .downloadFailed: return "downloadFailedSounds"
        case .error: return "errorSounds"
        case .splitOpened: return "splitOpenedSounds"
        case .splitClosed: return "splitClosedSounds"
        case .sitePinned: return "sitePinnedSounds"
        }
    }

    var resourceName: String {
        switch self {
        case .newTab: return "new-tab"
        case .notification: return "notification"
        case .downloadStarted: return "download-started"
        case .downloadComplete: return "download-complete"
        case .downloadFailed: return "download-failed"
        case .error: return "error"
        case .splitOpened: return "split-opened"
        case .splitClosed: return "split-closed"
        case .sitePinned: return "site-pinned"
        }
    }
}

/// Central playback for Breeze-owned interface sounds. Update sounds remain in
/// Updater.swift so their existing behavior and setting stay independent.
final class BreezeSounds {
    static let shared = BreezeSounds()

    private var sounds: [BreezeSoundEvent: NSSound] = [:]
    private let allowedVolumes = [10, 20, 50, 70, 100]

    private init() {}

    var volumePercent: Int {
        let stored = (Store.shared.settings["browserSoundVolume"] as? NSNumber)?.intValue ?? 10
        return allowedVolumes.contains(stored) ? stored : 10
    }

    func isEnabled(_ event: BreezeSoundEvent) -> Bool {
        Store.shared.settings[event.settingKey] as? Bool != false
    }

    func play(_ event: BreezeSoundEvent) {
        guard isEnabled(event) else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.play(event) }
            return
        }
        let sound: NSSound
        if let cached = sounds[event] {
            sound = cached
        } else {
            guard let url = Bundle.main.url(forResource: event.resourceName,
                                            withExtension: "mp3",
                                            subdirectory: "Sounds"),
                  let loaded = NSSound(contentsOf: url, byReference: false) else { return }
            sounds[event] = loaded
            sound = loaded
        }
        sound.stop()
        sound.currentTime = 0
        sound.volume = Float(volumePercent) / 100
        sound.play()
    }

    /// UserNotifications has no runtime volume property, so the bundle contains
    /// pre-scaled copies of the supplied notification sound.
    func notificationSound() -> UNNotificationSound? {
        guard isEnabled(.notification) else { return nil }
        let name = UNNotificationSoundName(rawValue: "BreezeNotification\(volumePercent).aiff")
        return UNNotificationSound(named: name)
    }
}
