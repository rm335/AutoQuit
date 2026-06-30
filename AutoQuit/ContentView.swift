// The heart of AutoQuit. This one file holds the engine that watches your
// running apps and quits the ones left idle too long, plus everything you see:
// the menu-bar popover (a row and countdown per app) and the Settings window.

import AppKit
import IOKit
import IOKit.pwr_mgt
import os
import ServiceManagement
import SwiftUI
import UserNotifications

// The built-in idle time (8 hours), kept in one place so every part of the app
// agrees on the same default.
enum AppDefaults {
    static let hoursUntilClose = 8
}

// A stable name tag for each app — its hidden bundle id, or its visible name if
// it has none. We use this to remember an app's settings even after it, or the
// whole Mac, has restarted.
extension NSRunningApplication {
    var toggleKey: String { bundleIdentifier ?? localizedName ?? "" }
}

// The single yes/no rule: should this app be quit right now? Kept separate and
// simple so it can be checked by automated tests.
enum QuitDecision {
    // Quit only if you haven't excluded it, it has finished starting up, and it
    // has now been idle longer than its time limit.
    static func shouldQuit(idle: TimeInterval, thresholdHours: Int,
                           isFinishedLaunching: Bool, optedOut: Bool) -> Bool {
        !optedOut && isFinishedLaunching && idle > Double(thresholdHours * 3600)
    }

    /// Per-app override wins; otherwise the global timeout. Pure, so it's unit-tested.
    static func effectiveHours(perApp: [String: Int], key: String, global: Int) -> Int {
        perApp[key] ?? global
    }
}

// The engine. It watches every running app, counts how long each has sat unused,
// warns you, and quits the ones idle past their limit. Everything else in the
// app is just buttons and labels sitting on top of this.
class RunningAppsManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    // Every app we're tracking, each paired with the last time it was in front.
    // "Idle" simply means how long ago that was.
    @Published var runningApps: [NSRunningApplication: Date] = [:]
    private var timer: Timer?
    private var deactivateToken: NSObjectProtocol?
    private var lastChecked = Date.distantPast
    // Your saved preferences. These survive quitting and reopening the app.
    @AppStorage("hoursUntilClose") var hoursUntilClose: Int = AppDefaults.hoursUntilClose
    @AppStorage("forceQuit") var forceQuit: Bool = false
    @AppStorage("skipBusyApps") var skipBusyApps: Bool = true
    @AppStorage("warnBeforeQuit") var warnBeforeQuit: Bool = true
    // The apps you've switched off (excluded from auto-quit). Saved automatically
    // the moment it changes.
    @Published var toggleStatus: [String: Bool] = [:] {
        didSet { saveToggleStatus() }
    }
    // Per-app custom time limits (e.g. quit this one after 2h instead of the
    // default). Also saved automatically.
    @Published var perAppHours: [String: Int] = [:] {
        didSet { savePerAppHours() }
    }

    // Where those two per-app lists are actually stored between launches.
    @AppStorage("com.AutoQuit.toggleStatus") var toggleStatusData: Data = Data()
    @AppStorage("com.AutoQuit.perAppHours") var perAppHoursData: Data = Data()

    // Quit-warning state, in-memory only: pid → when we posted the heads-up.
    private var warnedAt: [pid_t: Date] = [:]
    private var notificationAuthChecked = false
    private var notificationsDenied = false
    private static let warningCategory = "AUTOQUIT_WARNING"
    private let warningGrace: TimeInterval = 60   // ponytail: 60s lead is hardcoded; add a stepper only if asked

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "RunningAppsManager")

    override init() {
        super.init()
        // Load saved settings, then seed the list with apps that are already open.
        syncToggleStatus()
        syncPerAppHours()
        addCurrentRunningApps()

        log.debug("Init")
        // Whenever an app loses focus, stamp that as its "last used" time — that's
        // how we know how long it has been sitting idle.
        let center = NSWorkspace.shared.notificationCenter
        deactivateToken = center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                                             object: nil,
                                             queue: .main) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.log.debug("didDeactivate: \(app.localizedName ?? "Unknown", privacy: .public)")
            if !self.isBlockedApp(app) {
                self.runningApps[app] = Date()
            }
        }
        // Look once a second, but only do the real work when the menu is open (so
        // the countdowns tick live) or roughly once a minute otherwise. The rest
        // of the time it barely lifts a finger, to save battery.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let hasOpenWindow = NSApplication.shared.windows.contains { $0.isKeyWindow || $0.isMainWindow }

            if hasOpenWindow || Date().timeIntervalSince(self.lastChecked) >= 60 {
                self.checkOpenApps()
            }
        }
    }

    deinit {
        timer?.invalidate()
        if let deactivateToken {
            NSWorkspace.shared.notificationCenter.removeObserver(deactivateToken)
        }
        log.debug("RunningAppsManager is being deallocated")
    }

    // Load your saved per-app on/off choices back in when the app starts.
    private func syncToggleStatus() {
        guard !toggleStatusData.isEmpty else { return }   // first launch: nothing saved yet, not a failure
        do {
            toggleStatus = try JSONDecoder().decode([String: Bool].self, from: toggleStatusData)
        } catch {
            log.error("Failed to decode toggleStatus (opt-outs lost): \(error.localizedDescription, privacy: .public)")
        }
    }

    // Write the per-app on/off choices out so they survive a relaunch.
    func saveToggleStatus() {
        do {
            toggleStatusData = try JSONEncoder().encode(toggleStatus)
        } catch {
            log.error("Failed to encode toggleStatus (opt-outs not saved): \(error.localizedDescription, privacy: .public)")
        }
    }

    // Load your saved per-app time limits back in when the app starts.
    private func syncPerAppHours() {
        guard !perAppHoursData.isEmpty else { return }   // first launch: nothing saved yet, not a failure
        do {
            perAppHours = try JSONDecoder().decode([String: Int].self, from: perAppHoursData)
        } catch {
            log.error("Failed to decode perAppHours (per-app timeouts lost): \(error.localizedDescription, privacy: .public)")
        }
    }

    // Write the per-app time limits out so they survive a relaunch.
    func savePerAppHours() {
        do {
            perAppHoursData = try JSONEncoder().encode(perAppHours)
        } catch {
            log.error("Failed to encode perAppHours (per-app timeouts not saved): \(error.localizedDescription, privacy: .public)")
        }
    }

    // This app's idle limit: its own custom setting if you've set one, otherwise
    // the shared default.
    func effectiveHours(for app: NSRunningApplication) -> Int {
        QuitDecision.effectiveHours(perApp: perAppHours, key: app.toggleKey, global: hoursUntilClose)
    }

    // Finds apps that are actively doing something — playing video or music,
    // downloading, or holding the Mac awake — so we never quit them mid-task.
    /// pids currently asserting "don't sleep" — media playback, downloads, renders.
    /// One IOKit call, no entitlement; the single signal that an app is doing real work.
    private func busyPIDs() -> Set<pid_t> {
        var assertionsRef: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertionsRef) == kIOReturnSuccess,
              let byProcess = assertionsRef?.takeRetainedValue() as? [Int: [[String: Any]]]
        else { return [] }
        let busyTypes: Set<String> = [kIOPMAssertionTypePreventUserIdleSystemSleep,
                                      kIOPMAssertionTypePreventSystemSleep,
                                      kIOPMAssertionTypePreventUserIdleDisplaySleep]
        return Set(byProcess.compactMap { pid, list in
            list.contains { ($0[kIOPMAssertionTypeKey] as? String).map(busyTypes.contains) ?? false }
                ? pid_t(pid) : nil
        })
    }

    // Should this app be auto-quit at all? Yes by default, unless you've switched
    // it off. (Also checks an older-style saved setting so choices made before an
    // update still count.)
    func willAutoQuit(_ app: NSRunningApplication) -> Bool {
        toggleStatus[app.toggleKey] ?? toggleStatus[app.localizedName ?? ""] ?? true
    }

    // The safety list: apps AutoQuit must never touch. Background helpers and
    // menu-bar tools, AutoQuit itself, and Apple's own system apps (Finder, Dock,
    // Spotlight, Siri…) are always left alone. This filter exists because quitting
    // them caused real bugs — e.g. menu-bar utilities like Bartender getting
    // killed by mistake.
    private func isBlockedApp(_ app: NSRunningApplication) -> Bool {
        let currentAppBundleIdentifier = Bundle.main.bundleIdentifier
        let excludedIdentifiers = ["com.apple.loginwindow",
                                   "com.apple.systemuiserver",
                                   "com.apple.dock",
                                   "com.apple.finder",
                                   "com.apple.coreautha",
                                   "com.apple.Spotlight",
                                   "com.apple.notificationcenterui",
                                   "com.apple.Siri"
        ]
        if app.activationPolicy == .regular && app.bundleIdentifier != currentAppBundleIdentifier && !excludedIdentifiers.contains(app.bundleIdentifier ?? "") {
            return false
        }
        return true
    }

    // Add any apps that are already open (and allowed to be tracked) to the list,
    // starting their idle clock from now.
    private func addCurrentRunningApps() {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
        let currentDate = Date()

        for app in apps where !isBlockedApp(app) && runningApps[app] == nil {
            runningApps[app] = currentDate
        }
    }

    // The core loop, run on the timer. One pass: refresh the list of apps, work
    // out how long each has been idle, skip the ones we must leave alone or that
    // are busy, warn you, and finally quit anything past its limit.
    private func checkOpenApps() {
        let workspace = NSWorkspace.shared
        let currentDate = Date()
        lastChecked = currentDate

        // Forget any apps that have since quit on their own.
        let running = Set(workspace.runningApplications)
        runningApps = runningApps.filter { running.contains($0.key) }
        let runningPIDs = Set(running.map(\.processIdentifier))
        warnedAt = warnedAt.filter { runningPIDs.contains($0.key) }   // drop warnings for dead pids

        // Stop tracking anything that now belongs on the safety list.
        for app in runningApps.keys.filter({ isBlockedApp($0) }) {
            runningApps[app] = nil
        }

        // The app you're using right now counts as active — reset its idle clock.
        if let activeApp = workspace.frontmostApplication, !isBlockedApp(activeApp) {
            runningApps[activeApp] = currentDate
        }

        // Pick up any newly opened apps.
        addCurrentRunningApps()

        // Find which apps are busy (unless you've turned that option off), then go
        // through everything we're tracking.
        let busy = skipBusyApps ? busyPIDs() : []
        let tracked = runningApps
        for (app, startDate) in tracked {
            let pid = app.processIdentifier
            let idle = currentDate.timeIntervalSince(startDate)
            let threshold = effectiveHours(for: app)
            // Is this app actually due to be quit? If not (still in use, opted
            // out, or just reset), clear any pending warning and move on.
            guard QuitDecision.shouldQuit(idle: idle,
                                          thresholdHours: threshold,
                                          isFinishedLaunching: app.isFinishedLaunching,
                                          optedOut: !willAutoQuit(app))
            else { warnedAt[pid] = nil; continue }   // not eligible (idle reset / opted out) → drop any warning

            // 1. Busy (media, downloads, holding the Mac awake) → skip, don't reset the timer.
            if skipBusyApps && busy.contains(pid) {
                log.debug("Skipped \(app.localizedName ?? "?", privacy: .public) — busy (idle \(Int(idle))s)")
                continue
            }

            // 2. Warn first; quit only after the grace period lapses with no reprieve.
            if warnBeforeQuit && !notificationsDenied {
                if let warned = warnedAt[pid] {
                    if currentDate.timeIntervalSince(warned) < warningGrace { continue }
                } else {
                    warnedAt[pid] = currentDate
                    warn(app)
                    log.notice("Warned \(app.localizedName ?? "?", privacy: .public) (\(Int(self.warningGrace))s grace)")
                    continue
                }
            }

            // 3. Quit. Keep the rule: only stop tracking on a successful terminate.
            if forceQuit ? app.forceTerminate() : app.terminate() {
                runningApps[app] = nil
                warnedAt[pid] = nil
                log.notice("Quit \(app.localizedName ?? "?", privacy: .public) — idle \(Int(idle))s ≥ \(threshold)h")
            } else {
                log.error("Quit FAILED for \(app.localizedName ?? "?", privacy: .public) — idle \(Int(idle))s")
            }
        }
    }

    // Quit warning (UserNotifications). Delegate is the manager itself; wired in AutoQuitApp.

    // Set up the two buttons that appear on the warning notice: "Keep" (leave the
    // app running) and "Quit now".
    func registerNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let keep = UNNotificationAction(
            identifier: "KEEP",
            title: String(localized: "Keep", comment: "Notification action: keep the idle app running"),
            options: [])
        let quitNow = UNNotificationAction(
            identifier: "QUIT_NOW",
            title: String(localized: "Quit now", comment: "Notification action: quit the idle app immediately"),
            options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.warningCategory, actions: [keep, quitNow],
                                   intentIdentifiers: [], options: [])
        ])
    }

    // Post the heads-up that an app is about to be quit. The very first time this
    // is needed it asks your permission to send notifications; if you decline,
    // AutoQuit simply quits idle apps without warning from then on.
    private func warn(_ app: NSRunningApplication) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Quitting \(app.localizedName ?? "an app")",
                               comment: "Auto-quit warning notification title")
        content.body = String(localized: "Idle too long — closing in 60 seconds. Keep it open?",
                              comment: "Auto-quit warning notification body")
        content.sound = .default
        content.categoryIdentifier = Self.warningCategory
        content.userInfo = ["toggleKey": app.toggleKey, "pid": Int(app.processIdentifier)]
        let request = UNNotificationRequest(identifier: app.toggleKey, content: content, trigger: nil)

        let center = UNUserNotificationCenter.current()
        guard !notificationAuthChecked else { center.add(request); return }
        // Lazy first-time authorization. Denial falls back to quitting without a warning.
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.notificationAuthChecked = true
                if let error {
                    self?.log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                }
                if granted {
                    center.add(request)
                } else {
                    self?.notificationsDenied = true
                    self?.log.notice("Notifications denied — quitting without warning")
                }
            }
        }
    }

    // Show the warning as a banner even while AutoQuit is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Handle your tap on the warning: "Quit now" quits immediately, while "Keep"
    // (or tapping the notice itself) resets the idle clock so the app stays open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let pid = pid_t(info["pid"] as? Int ?? -1)
        DispatchQueue.main.async { [weak self] in
            guard let self else { completionHandler(); return }
            let app = self.runningApps.keys.first { $0.processIdentifier == pid }
            switch response.actionIdentifier {
            case "QUIT_NOW":
                if let app { _ = self.forceQuit ? app.forceTerminate() : app.terminate() }
                self.warnedAt[pid] = nil
            case "KEEP", UNNotificationDefaultActionIdentifier:
                if let app { self.runningApps[app] = Date() }   // reset idle timer, like the row's reset button
                self.warnedAt[pid] = nil
            default:
                break   // dismissed/ignored → leave warnedAt so the grace period proceeds to quit
            }
            completionHandler()
        }
    }
}

private extension View {
    @ViewBuilder
    func glassCard<S: InsettableShape>(_ shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.quaternary, lineWidth: 1) }
        }
    }
}

// The popover that drops down from the menu-bar icon: the list of tracked apps
// (or a friendly empty state), with Settings and Quit buttons at the bottom.
struct ContentView: View {
    @ObservedObject private var manager: RunningAppsManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(manager: RunningAppsManager) {
        self.manager = manager
    }

    private var sortedApps: [NSRunningApplication] {
        manager.runningApps.keys.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            if manager.runningApps.isEmpty {
                EmptyTrackingView()
            } else {
                appList
            }
            footer
        }
        .frame(width: 320)
    }

    private var appList: some View {
        // Redraw once a second so every countdown stays live while the menu is open.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let apps = sortedApps
            let list = VStack(spacing: 2) {
                ForEach(apps, id: \.self) { app in
                    AppRow(app: app,
                           lastActive: manager.runningApps[app] ?? context.date,
                           now: context.date,
                           manager: manager)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(8)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                       value: apps.map(\.processIdentifier))

            // Cap the scrollable list at two-thirds the screen height; grow inline until apps would exceed it.
            let maxHeight = (NSScreen.main?.frame.height ?? 800) * 2 / 3
            let contentHeight = CGFloat(apps.count) * 40 + 16   // ponytail: ~40pt/row estimate; retune if AppRow height changes
            if contentHeight > maxHeight {
                ScrollView { list }.frame(height: maxHeight)
            } else {
                list
            }
        }
    }

    private var footer: some View {
        Group {
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: 6) {
                    VStack(spacing: 6) {
                        commandButton("Close all selected", "xmark.circle") { closeSelected(force: false) }
                            .disabled(!hasSelection)
                        commandButton("Force close all selected", "xmark.octagon", iconColor: .red) { closeSelected(force: true) }
                            .disabled(!hasSelection)
                        commandButton("Settings", "gearshape") { SettingsWindowController.show() }
                        commandButton("Quit AutoQuit", "power") { NSApplication.shared.terminate(nil) }
                    }
                }
            } else {
                VStack(spacing: 2) {
                    MenuCommandButton(title: "Close all selected", systemImage: "xmark.circle") {
                        closeSelected(force: false)
                    }
                    .disabled(!hasSelection)
                    MenuCommandButton(title: "Force close all selected", systemImage: "xmark.octagon", iconColor: .red) {
                        closeSelected(force: true)
                    }
                    .disabled(!hasSelection)
                    MenuCommandButton(title: "Settings", systemImage: "gearshape") {
                        SettingsWindowController.show()
                    }
                    MenuCommandButton(title: "Quit AutoQuit", systemImage: "power") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .padding(8)
    }

    @available(macOS 26, *)
    private func commandButton(_ title: LocalizedStringKey, _ systemImage: String,
                               iconColor: Color? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if let iconColor {
                    Image(systemName: systemImage).foregroundStyle(iconColor)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text(title))
    }

    private var hasSelection: Bool {
        manager.runningApps.keys.contains { manager.willAutoQuit($0) }
    }

    private func closeSelected(force: Bool) {
        for app in Array(manager.runningApps.keys) where manager.willAutoQuit(app) {
            _ = force ? app.forceTerminate() : app.terminate()
        }
        // No manual cleanup: the 1s timer in RunningAppsManager prunes apps that
        // have quit, same as the per-row close buttons rely on.
    }
}

// A row-style button used in the popover footer on older macOS versions.
private struct MenuCommandButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var iconColor: Color? = nil
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if let iconColor {
                    Image(systemName: systemImage).foregroundStyle(iconColor)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? Color.white : Color.primary)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
        .onHover { hovering in
            guard !reduceMotion else { isHovering = hovering; return }
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .accessibilityLabel(Text(title))
    }
}

// The friendly placeholder shown when there are no apps to track yet.
private struct EmptyTrackingView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 76, height: 76)
                .glassCard(Circle())
            VStack(spacing: 4) {
                Text("No apps to track")
                    .font(.headline)
                Text("Apps you open appear here with a countdown until they’re auto-quit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

// The custom look of the on/off switch shown next to each app.
private struct AutoQuitToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }

    private struct SwitchBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private let trackW: CGFloat = 32
        private let trackH: CGFloat = 18
        private let knob: CGFloat = 14

        var body: some View {
            let on = configuration.isOn
            Button {
                configuration.isOn.toggle()
            } label: {
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule()
                        .fill(on ? AnyShapeStyle(Color.accentColor.gradient)
                            : AnyShapeStyle(Color.primary.opacity(0.16)))
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(on ? 0 : 0.07), lineWidth: 0.5)
                        }
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                        .padding(2)
                        .scaleEffect(hovering ? 1.08 : 1)
                }
                .frame(width: trackW, height: trackH)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: on)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

// One row in the popover for a single app: its on/off switch, icon, name, the
// countdown pill (which also opens a menu to set a custom limit), a reset button,
// and an optional quit-now button.
struct AppRow: View {
    let app: NSRunningApplication
    let lastActive: Date
    let now: Date
    @ObservedObject var manager: RunningAppsManager
    @AppStorage("hoursUntilClose") private var hoursUntilClose = AppDefaults.hoursUntilClose
    @AppStorage("forceQuit") private var forceQuit = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayName: String {
        app.localizedName ?? String(localized: "Unknown", comment: "Fallback shown when an app has no name")
    }
    private var willQuit: Bool { manager.willAutoQuit(app) }

    private var secondsLeft: Int {
        max(0, manager.effectiveHours(for: app) * 3600 - Int(now.timeIntervalSince(lastActive)))
    }

    private var shouldQuitCheckbox: Binding<Bool> {
        Binding(
            get: { manager.willAutoQuit(app) },
            set: { newValue in
                manager.toggleStatus[app.toggleKey] = newValue
            }
        )
    }

    // 0 = "use the global default"; any other value is a per-app override.
    private var timeoutBinding: Binding<Int> {
        Binding(
            get: { manager.perAppHours[app.toggleKey] ?? 0 },
            set: { manager.perAppHours[app.toggleKey] = $0 == 0 ? nil : $0 }
        )
    }

    private var statusColor: Color {
        guard willQuit else { return .secondary }
        if secondsLeft <= 300 { return .red }
        if secondsLeft <= 3600 { return .orange }
        return .secondary
    }

    private var statusText: String {
        willQuit
            ? IdleTime.short(secondsLeft)
            : String(localized: "Excluded", comment: "Countdown pill: app is opted out of auto-quit")
    }

    private var statusAccessibility: String {
        willQuit
            ? String(localized: "Quits in \(IdleTime.verbose(secondsLeft))",
                     comment: "Accessibility: time until auto-quit, e.g. “Quits in 1 hour, 30 minutes”")
            : String(localized: "Excluded from auto-quit", comment: "Accessibility: app is opted out of auto-quit")
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: shouldQuitCheckbox) {
                Text("Auto-quit \(displayName)")
            }
            .toggleStyle(AutoQuitToggleStyle())
            .help(willQuit ? "Stop auto-quitting \(displayName)" : "Auto-quit \(displayName) when idle")

            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .opacity(willQuit ? 1 : 0.5)
                    .accessibilityHidden(true)
            }

            Text(displayName)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(willQuit ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Picker("Idle timeout", selection: timeoutBinding) {
                    Text("Use default (\(hoursUntilClose)h)").tag(0)
                    // ponytail: fixed timeout choices; no custom-value entry unless asked
                    ForEach([1, 2, 4, 8, 12, 24, 48], id: \.self) { Text("\($0)h").tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                CountdownPill(text: statusText, color: statusColor, accessibility: statusAccessibility)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: statusColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Set how long \(displayName) can stay idle before quitting")

            Button {
                manager.runningApps[app] = Date()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!willQuit)
            .help("Reset the idle timer for \(displayName)")
            .accessibilityLabel("Reset idle timer for \(displayName)")

            Button {
                app.terminate()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Quit \(displayName)")
            .accessibilityLabel("Quit \(displayName)")

            Button {
                app.forceTerminate()
            } label: {
                Image(systemName: "xmark.octagon")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Force quit \(displayName) — discards unsaved changes")
            .accessibilityLabel("Force quit \(displayName) — discards unsaved changes")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !reduceMotion else { isHovering = hovering; return }
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

// The small colored pill showing the time left (or "Excluded").
private struct CountdownPill: View {
    let text: String
    let color: Color
    let accessibility: String

    var body: some View {
        Text(text)
            .font(.callout)
            .fontWeight(.medium)
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .accessibilityLabel(accessibility)
    }
}

// Turns a number of seconds into short, readable text like "2h" or "45s".
enum IdleTime {
    // Locale-aware duration rendering. Behavior preserved from the old hand-rolled
    // version: show seconds only when under a minute, otherwise hours/minutes with
    // zero units dropped. We pre-truncate to whole minutes so the formatter never
    // rounds 1h0m59s up to "1h 1m" (integer division did the same before).
    // `locale` defaults to the user's current locale (the UI wants that); tests pin
    // it to en_US so the asserted strings are deterministic on any host/CI.
    private static func format(_ seconds: Int, width: Duration.UnitsFormatStyle.UnitWidth,
                               locale: Locale) -> String {
        let s = max(0, seconds)
        if s < 60 {
            return Duration.seconds(s).formatted(
                .units(allowed: [.seconds], width: width, zeroValueUnits: .show(length: 1))
                    .locale(locale))
        }
        let wholeMinutes = (s / 60) * 60
        return Duration.seconds(wholeMinutes).formatted(
            .units(allowed: [.hours, .minutes], width: width).locale(locale))
    }

    static func short(_ seconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        format(seconds, width: .narrow, locale: locale)
    }
    static func verbose(_ seconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        format(seconds, width: .wide, locale: locale)
    }
}

// Manages the Settings window. It remembers the one already open, so clicking
// Settings again just brings it back to the front instead of opening a second.
class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static var current: SettingsWindowController?

    convenience init(rootView: SettingsView) {
        // Fit the window to its content, but never taller than two-thirds of the screen.
        // fixedSize stops the grouped Form greedily filling, so sizeThatFits reports the real content height.
        let cap = (NSScreen.main?.frame.height ?? 800) * 2 / 3
        let ideal = NSHostingController(
            rootView: rootView.frame(width: 480).fixedSize(horizontal: false, vertical: true)
        ).sizeThatFits(in: CGSize(width: 480, height: CGFloat.greatestFiniteMagnitude)).height
        let hostingController = NSHostingController(rootView: rootView.frame(width: 480, height: min(ideal, cap)))
        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "Settings", comment: "Settings window title")
        self.init(window: window)
        window.delegate = self
        SettingsWindowController.current = self
    }

    // Open Settings (or re-focus it if already open). While it's open the app
    // briefly takes on a normal Dock presence so the window can come forward.
    static func show() {
        NSApp.setActivationPolicy(.regular)
        let controller = current ?? SettingsWindowController(rootView: SettingsView())
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // When Settings closes, slip back to menu-bar-only (no Dock icon).
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    deinit {
        SettingsWindowController.current = nil
    }
}

// The Settings window's contents: launch-at-login, the idle timeout, and the
// options for how idle apps are handled.
struct SettingsView: View {
    @AppStorage("hoursUntilClose") private var hoursUntilClose = AppDefaults.hoursUntilClose
    @AppStorage("forceQuit") private var forceQuit = false
    @AppStorage("skipBusyApps") private var skipBusyApps = true
    @AppStorage("warnBeforeQuit") private var warnBeforeQuit = true

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private var appBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            Form {
                Section("General") {
                    LaunchAtLoginToggle()
                }

                Section {
                    Stepper("Quit apps after \(hoursUntilClose)h of inactivity",
                            value: $hoursUntilClose, in: 1 ... 72)
                } header: {
                    Text("Idle timeout")
                } footer: {
                    Text("Set per-app exceptions from the menu bar list.")
                }

                Section {
                    Toggle("Don’t quit busy apps", isOn: $skipBusyApps)
                    Toggle("Warn before quitting", isOn: $warnBeforeQuit)
                } header: {
                    Text("When idle")
                } footer: {
                    Text("“Busy” means playing media, downloading, or keeping the Mac awake. A warning lets you keep an app before it’s quit.")
                }

                Section {
                    Toggle("Force quit without saving", isOn: $forceQuit)
                } header: {
                    Text("Quitting")
                } footer: {
                    Text(forceQuit
                        ? "Force quit ends apps immediately and discards unsaved changes."
                        : "Apps are asked to quit normally, so you can save your work.")
                }
            }
            .formStyle(.grouped)
        }
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Image("Image")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("AutoQuit")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Version \(appVersion) (\(appBuildNumber))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(manager: runningAppsManager)
    }
}

// The "Launch at login" switch. Flipping it asks macOS to start (or stop
// starting) AutoQuit automatically when you log in.
struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { isEnabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    isEnabled = newValue
                } catch {
                    isEnabled = SMAppService.mainApp.status == .enabled
                }
            }
        ))
    }
}
