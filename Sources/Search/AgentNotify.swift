import AppKit
import AudioToolbox
import UserNotifications

// Mac notifications for tabsh's cards, apart from the ones a website sends
// (see Notifications.swift). An agent that needs you says so when its card
// moves to Needs input, and one that finished when its card moves to
// Completed — whether the tab is behind another or not open at all. The
// click brings the card's tab forward, opening it if it has none.
//
// The moves come from the daemon's board socket, and only a hook's or the
// ACP agent's own move tells: a card you drag yourself is not news to you
// (see TabshSessions.handle). Everything is drawn by macOS through
// UserNotifications, so a notification is a real one in Notification Center,
// with Focus, Do Not Disturb and the rest applying as they do to any app.
//
// One app has one notification delegate, and SiteNotifications already is
// it; a click is routed there and handed back here by `search.kind` in the
// notification's userInfo.
//
// The chime plays even when macOS refuses the banner (as the web app's
// notify.ts does): permission is asked the first time a post is due, and
// the banner is only added once authorization has answered — posting in the
// same breath as the ask used to lose the first notification.

@MainActor
enum AgentNotify {
    /// The userInfo key `SiteNotifications.clicked` reads. The session id
    /// travels beside it under "search.session".
    static let kind = "agent"

    /// Whether macOS has been asked, this run, whether Tabs may notify.
    private static var asked = false

    /// What a test run would have posted, newest last (see Store.testing).
    private(set) static var recorded: [[String: String]] = []

    /// Clears `recorded`, between test cases.
    static func clearRecorded() { recorded.removeAll() }

    /// Whether a notification can be posted at all. A test run (and a bench
    /// run, which is the app in a test world) posts nothing: a real banner
    /// would land on the screen of whoever is working beside it. Outside an
    /// app bundle — a test runner, a bare `swift run` — the notification
    /// centre throws rather than answering, so only the app asks it.
    private static var posts: Bool {
        !Store.testing && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Asks macOS for permission. Called when the first switch in Settings ›
    /// Agents › Notifications goes on, so the prompt comes while the person
    /// is looking at the setting rather than in the middle of a turn; also
    /// when the board starts listening, and before a post, so the first
    /// banner is not lost to the race of asking and adding in one breath.
    static func ask() {
        guard posts else { return }
        let center = UNUserNotificationCenter.current()
        // The click has to reach SiteNotifications, the app's one delegate.
        if center.delegate == nil { center.delegate = SiteNotifications.shared }
        guard !asked else { return }
        asked = true
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            default:
                break
            }
        }
    }

    /// A card moved, from the board socket. Only Needs input and Completed
    /// are worth a notification, and only the move into one of them: a
    /// repeated event is not a new thing to say.
    static func moved(_ info: Tabsh.SessionInfo, to status: TabshStatus) {
        let prefs = Shared.prefs
        switch status {
        case .needsInput:
            guard prefs.agentNotifyNeeds else { return }
        case .completed:
            guard prefs.agentNotifyDone else { return }
        default:
            return
        }
        // Already on screen: a banner over a page you are reading is noise.
        guard !(prefs.agentNotifyBackground && onScreen(info.id)) else { return }

        let who = info.agentName ?? info.name
        let content = UNMutableNotificationContent()
        content.title = info.name
        if who != info.name { content.subtitle = who }
        switch status {
        case .needsInput:
            content.body = nonEmpty(info.note) ?? "Needs input"
        case .completed:
            content.body = nonEmpty(info.note) ?? "Finished"
        default:
            return
        }
        content.threadIdentifier = "tabsh.\(info.id)"
        // The banner is silent: the chime below is the sound, as the web
        // app's notification is silent and plays its own. That way a denied
        // permission still leaves a sound, and an allowed one does not ring
        // twice.
        content.sound = nil
        content.userInfo = ["search.kind": kind, "search.session": info.id]
        if !posts {
            recorded.append(["title": content.title, "body": content.body, "session": info.id])
            return
        }
        if prefs.agentNotifySound { chime(for: status) }
        deliver(content, identifier: "tabsh|\(info.id)")
    }

    /// A clicked notification: the card's tab in front, opened if it has
    /// none. A card that is gone from the daemon still has its tab, and the
    /// tab knows how to say so.
    static func show(_ session: String) {
        for browser in Browsers.all {
            let tabs = browser.tabs + browser.parkedTabs
            guard let tab = tabs.first(where: isSession(session)) else { continue }
            browser.select(tab)
            Browsers.show(browser)
            NSApp.activate()
            return
        }
        guard let browser = Browsers.front ?? Browsers.all.last else { return }
        let kind: InternalPage.Kind = TabshSessions.shared.info(for: session)?.mode == "ui" ? .agent : .tabsh
        browser.show(InternalPage(kind, session))
        Browsers.show(browser)
        NSApp.activate()
    }

    // MARK: - posting

    /// Adds the banner only once macOS has said the app may notify. Asking
    /// and adding in one breath used to drop the first one: the add ran
    /// while authorization was still `.notDetermined`.
    private static func deliver(_ content: UNMutableNotificationContent, identifier: String) {
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = SiteNotifications.shared }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                }
            default:
                // Denied or restricted: the chime already played; the banner
                // cannot. System Settings › Notifications › Tabs is the way
                // back.
                break
            }
        }
    }

    /// A short system chime: Needs input is the questioning "Tink", Finished
    /// is the clearer "Glass". Kept off the notification itself so a denied
    /// permission still makes a sound.
    private static func chime(for status: TabshStatus) {
        let name: NSSound.Name = status == .completed ? "Glass" : "Tink"
        if let sound = NSSound(named: name) {
            sound.play()
        } else {
            AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
        }
    }

    /// Whether the card's tab is the one in front of a window the person is
    /// looking at. A card open in another space, or behind another tab, is
    /// not on screen.
    private static func onScreen(_ session: String) -> Bool {
        guard NSApp.isActive else { return false }
        for browser in Browsers.all where browser.isOpen {
            guard browser === Browsers.front,
                  let active = browser.activeID,
                  let tab = (browser.tabs + browser.parkedTabs).first(where: isSession(session)),
                  tab.id == active
            else { continue }
            return true
        }
        return false
    }

    private static func isSession(_ session: String) -> (Tab) -> Bool {
        { tab in
            guard let page = tab.page else { return false }
            return page.detail == session && (page.kind == .agent || page.kind == .tabsh)
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
