import AppKit
import SwiftUI

// AppDelegate owns long-lived singletons. It does no work itself - the
// pipeline lives in AppCoordinator, the menu bar in MenuBarController, and
// settings in SettingsStore. Keeping this thin makes it easy to find where
// any given behaviour actually lives.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator!
    private var menuBar: MenuBarController!
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private let updater = Updater()
    // Built in applicationDidFinishLaunching (not a property initializer):
    // Notifier is @MainActor-isolated, and AppDelegate itself isn't - the
    // same reason coordinator/menuBar above are implicitly-unwrapped rather
    // than given default values.
    private var notifier: Notifier!

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()
        menuBar = MenuBarController(
            coordinator: coordinator,
            queue: TranscriptionQueue.shared,
            onShowAbout: { [weak self] in self?.showAbout() },
            onShowSettings: { [weak self] in self?.showSettings() },
            onShowHistory: { [weak self] in self?.showHistory() },
            onShowOnboarding: { [weak self] in self?.showOnboarding() },
            onQuit: { NSApp.terminate(nil) }
        )

        // Give the app a menu bar for when it's promoted to .regular (a window
        // is open). Harmless while .accessory - macOS simply doesn't show it.
        installMainMenu()

        // Wire the global Quit hotkey (⌃⌥Q) through the same closure the
        // status-bar Quit item uses, so a hotkey press and a menu click are
        // indistinguishable downstream.
        coordinator.setMenuActions(
            quit: { NSApp.terminate(nil) }
        )

        // Wired before start(): the startup scan can complete queued jobs
        // immediately, and their notifications need the real notifier.
        notifier = Notifier()
        notifier.onOpenHistory = { [weak self] in self?.showHistory() }
        TranscriptionQueue.shared.notifier = notifier

        coordinator.start()

        // The onboarding "Restart" button relaunches with this transient flag
        // (NSArgumentDomain, not persisted) so we reopen onboarding even when a
        // returning user's grants are now all complete - otherwise clicking
        // Restart drops them into an empty menu bar. See OnboardingView.quitAndRelaunch.
        let relaunchedToOnboarding = UserDefaults.standard.bool(forKey: "BarktorRelaunchToOnboarding")
        if relaunchedToOnboarding || !SettingsStore.shared.onboardingDone || !Permissions.allGranted() {
            // First launch, or a regression from a permission being revoked
            // (System Settings can flip these any time): walk the user
            // through the three TCC prompts before they try to use a hotkey
            // that won't fire.
            //
            // Deferred one runloop tick: showOnboarding() promotes the app to
            // .regular (Dock icon + Cmd-Tab) via syncActivationPolicy(), but
            // setActivationPolicy doesn't take effect when called synchronously
            // inside didFinishLaunching - the change lands asynchronously, after
            // launch completes. Called inline, the Dock icon never appears at
            // first launch or after a Restart relaunch until a later window open
            // re-triggers the policy; deferred, launch itself surfaces
            // onboarding with full Dock/Cmd-Tab presence.
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        }
    }

    // Barktor has no Dock icon, and a crowded menu bar (or the notch) can push
    // its status item out of sight - leaving no visible way into the app.
    // Opening Barktor again from Finder/Launchpad/Spotlight lands here: surface
    // the right window instead of doing nothing. Onboarding while setup is
    // incomplete, Settings otherwise.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            if !SettingsStore.shared.onboardingDone || !Permissions.allGranted() {
                showOnboarding()
            } else {
                showSettings()
            }
        }
        // With windows already visible, returning true lets AppKit bring
        // them to the front.
        return true
    }

    private func showOnboarding() {
        if let win = onboardingWindow {
            present(win)
            return
        }
        // textSelection lets the user drag-select and copy any text in the
        // window (permission descriptions, shortcuts) out to other apps.
        // "Start Using Barktor" closes this window; the app stays alive in the
        // menu bar (isReleasedWhenClosed is false, so it can be reopened from
        // the menu). The window isn't assigned to onboardingWindow until below,
        // so capture self and read it lazily when the button fires.
        let view = OnboardingView(onFinish: { [weak self] in self?.onboardingWindow?.close() })
            .textSelection(.enabled)
        let host = NSHostingController(rootView: view)
        // Size the window to the SwiftUI content's ideal size. OnboardingView
        // pins its own width, so this yields a window sized exactly to the
        // content - no clipping, no empty padding.
        host.sizingOptions = .preferredContentSize
        let win = NSWindow(contentViewController: host)
        win.title = "Welcome to Barktor"
        win.styleMask = [.titled, .closable]
        win.center()
        win.isReleasedWhenClosed = false
        onboardingWindow = win
        observeClose(win)
        present(win)
    }

    private func showAbout() {
        if let win = aboutWindow {
            present(win)
            return
        }
        let view = AboutView(updater: updater, coordinator: coordinator).textSelection(.enabled)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "About Barktor"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 380, height: 332))
        win.center()
        win.isReleasedWhenClosed = false
        aboutWindow = win
        observeClose(win)
        present(win)
    }

    private func showSettings() {
        if let win = settingsWindow {
            present(win)
            return
        }
        let view = SettingsView(
            coordinator: coordinator,
            onShowAbout: { [weak self] in self?.showAbout() }
        ).textSelection(.enabled)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Barktor - Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 560, height: 600))
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        observeClose(win)
        present(win)
    }

    private func showHistory() {
        if let win = historyWindow {
            present(win)
            return
        }
        let view = HistoryView(coordinator: coordinator).textSelection(.enabled)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Barktor - History"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 560, height: 520))
        win.center()
        win.isReleasedWhenClosed = false
        historyWindow = win
        observeClose(win)
        present(win)
    }

    // ------------------------------------------------------------------
    // Dock / Cmd-Tab presence
    // ------------------------------------------------------------------

    // Bring a window forward and reconcile Dock/Cmd-Tab presence. Every show
    // path funnels through here so the activation policy is never left stale.
    private func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncActivationPolicy()
    }

    // Barktor launches as .accessory (menu-bar only: no Dock icon, absent from
    // Cmd-Tab). Fine until a window is open and the user switches away - there's
    // then no way back except hunting for the status-bar glyph. So we promote to
    // .regular (Dock icon + Cmd-Tab entry) whenever any of our windows is
    // visible, and demote back to .accessory when the last one closes, melting
    // the app back into the menu bar. The RecordingHUD panel isn't tracked here,
    // so dictation never spawns a Dock icon.
    private func syncActivationPolicy() {
        let anyVisible = [onboardingWindow, settingsWindow, historyWindow, aboutWindow]
            .contains { $0?.isVisible == true }
        NSApp.setActivationPolicy(anyVisible ? .regular : .accessory)
    }

    // Recount presence when a window closes. willClose fires *before* the
    // window's isVisible flips to false, so defer one runloop tick before
    // recounting. Windows are created once (isReleasedWhenClosed = false) and
    // reused, so each observer is registered once and lives for the app's
    // lifetime - no token bookkeeping needed.
    // ponytail: observer token intentionally discarded; app-lifetime by design.
    private func observeClose(_ window: NSWindow) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.syncActivationPolicy() }
        }
    }

    // A minimal main menu. In .accessory mode macOS shows no menu bar, but the
    // moment syncActivationPolicy() promotes the app to .regular the top-of-
    // screen menu bar appears - and without this it would be empty. The Edit
    // menu is the real payoff: its standard items give ⌘X/⌘C/⌘V/⌘A a home so
    // they finally work inside the Settings and History text fields.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu (rendered bold, titled after the app). Reuses the same
        // actions the status-bar menu offers.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Barktor", action: #selector(menuAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        // ⌘Q quits the focused app the way every Mac app does; the global ⌃⌥Q
        // hotkey (HotkeyManager) still quits when no window has focus.
        appMenu.addItem(withTitle: "Quit Barktor", action: #selector(menuQuit), keyEquivalent: "q")
        for item in appMenu.items where item.action != nil { item.target = self }

        // Edit menu - target stays nil so each command routes down the responder
        // chain to whichever text field is first responder.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc private func menuAbout() { showAbout() }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}
