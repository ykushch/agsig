import AppKit
import HerdrClient

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var viewModel: NotchViewModel?
    private var hotkeyMonitor: HotkeyMonitor?
    private var menuBar: MenuBarController?
    private var settings: Settings?
    private var soundEngine: SoundEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings()
        let model = NotchViewModel(client: HerdrClient(socketPath: settings.resolvedSocketPath()))
        let sound = SoundEngine(settings: settings)
        model.settings = settings
        model.soundEngine = sound

        let controller = NotchWindowController(viewModel: model, settings: settings)
        controller.show()
        model.start()

        let monitor = HotkeyMonitor(viewModel: model, settings: settings)
        monitor.start()
        if !HotkeyMonitor.accessibilityGranted() { HotkeyMonitor.promptForAccessibility() }

        let menuBar = MenuBarController(
            settings: settings,
            onSessionChange: { [weak model, weak settings] in
                guard let model, let settings else { return }
                model.reconnect(socketPath: settings.resolvedSocketPath())
            },
            onToggleNotch: { [weak model] in model?.toggle() }
        )
        menuBar.install()

        self.settings = settings
        soundEngine = sound
        viewModel = model
        notchController = controller
        hotkeyMonitor = monitor
        self.menuBar = menuBar
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
        viewModel?.stop()
        menuBar?.remove()
        notchController?.tearDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
