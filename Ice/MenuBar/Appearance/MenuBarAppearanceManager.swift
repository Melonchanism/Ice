//
//  MenuBarAppearanceManager.swift
//  Ice
//

import Cocoa
import Combine

/// A manager for the appearance of the menu bar.
@MainActor
final class MenuBarAppearanceManager: ObservableObject, BindingExposable {
    /// The current menu bar appearance configuration.
    @Published var configuration: MenuBarAppearanceConfigurationV2 = .defaultConfiguration

    /// The currently previewed partial configuration.
    @Published var previewConfiguration: MenuBarAppearancePartialConfiguration?
    
    /// Detects if mission control is open, useful for deciding when to hide and show.
    @Published var missionControlActive: Bool = false

    /// The shared app state.
    private weak var appState: AppState?

    /// Encoder for UserDefaults values.
    private let encoder = JSONEncoder()

    /// Decoder for UserDefaults values.
    private let decoder = JSONDecoder()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The currently managed menu bar overlay panels.
    private(set) var overlayPanels = Set<MenuBarOverlayPanel>()

    /// The amount to inset the menu bar if called for by the configuration.
    let menuBarInsetAmount: CGFloat = 5

    /// Creates a manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Performs initial setup of the manager.
    func performSetup() {
        loadInitialState()
        configureCancellables()
    }

    /// Loads the initial values for the configuration.
    private func loadInitialState() {
        do {
            if let data = Defaults.data(forKey: .menuBarAppearanceConfigurationV2) {
                configuration = try decoder.decode(MenuBarAppearanceConfigurationV2.self, from: data)
            }
        } catch {
            Logger.appearanceManager.error("Error decoding configuration: \(error)")
        }
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                while let panel = overlayPanels.popFirst() {
                    panel.orderOut(self)
                }
                if Set(overlayPanels.map { $0.owningScreen }) != Set(NSScreen.screens) {
                    configureOverlayPanels(with: configuration)
                }
            }
            .store(in: &c)

        // Props to Yabai
        let customPort = Port()
        RunLoop.current.add(customPort, forMode: .default)
        let thread = Thread {
            let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")[0].processIdentifier
            var observer: AXObserver?
            let element: AXUIElement = AXUIElementCreateApplication(dockPid)
            AXObserverCreate(dockPid, updateExposeStatus, &observer)
            if let observer = observer {
                AXObserverAddNotification(observer, element, .kAXExposeExit, nil)
                AXObserverAddNotification(observer, element, .kAXExposeShowDesktop, nil)
                AXObserverAddNotification(observer, element, .kAXExposeShowAllWindows, nil)
                AXObserverAddNotification(observer, element, .kAXExposeShowFrontWindows, nil)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
                RunLoop.current.run()
            }
        }
        thread.start()

        $configuration
            .encode(encoder: encoder)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    Logger.appearanceManager.error("Error encoding configuration: \(error)")
                }
            } receiveValue: { data in
                Defaults.set(data, forKey: .menuBarAppearanceConfigurationV2)
            }
            .store(in: &c)

        $configuration
            .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] configuration in
                guard let self else {
                    return
                }
                // The overlay panels may not have been configured yet. Since some of the
                // properties on the manager might call for them, try to configure now.
                if overlayPanels.isEmpty {
                    configureOverlayPanels(with: configuration)
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a Boolean value that indicates whether a set of overlay panels
    /// is needed for the given configuration.
    private func needsOverlayPanels(for configuration: MenuBarAppearanceConfigurationV2) -> Bool {
        let current = configuration.current
        if current.hasShadow || current.hasBorder || configuration.shapeKind != .none || current.tintKind != .none {
            return true
        }
        return false
    }

    /// Configures the manager's overlay panels, if required by the given configuration.
    private func configureOverlayPanels(with configuration: MenuBarAppearanceConfigurationV2) {
        guard let appState, needsOverlayPanels(for: configuration)
        else {
            while let panel = overlayPanels.popFirst() { panel.close() }
            return
        }

        var overlayPanels = Set<MenuBarOverlayPanel>()
        for screen in NSScreen.screens {
            let panel = MenuBarOverlayPanel(appState: appState, owningScreen: screen)
            overlayPanels.insert(panel)
            panel.needsShow = true
        }

        self.overlayPanels = overlayPanels
    }

    /// Sets the value of ``MenuBarOverlayPanel.isDraggingMenuBarItem`` for each
    /// of the manager's overlay panels.
    func setIsDraggingMenuBarItem(_ isDragging: Bool) {
        for panel in overlayPanels {
            panel.isDraggingMenuBarItem = isDragging
        }
    }
}

// MARK: - Logger
private extension Logger {
    /// The logger to use for the menu bar appearance manager.
    static let appearanceManager = Logger(category: "MenuBarAppearanceManager")
}

// MARK: C-compatible way to capture the AX Notificaiton and redirect it back to regular swift
func updateExposeStatus(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    Task {
        print(notification)
        if notification == CFString.kAXExposeExit {
            await AppState.shared.appearanceManager.setIsDraggingMenuBarItem(false)
        } else {
            await AppState.shared.appearanceManager.setIsDraggingMenuBarItem(true)
        }
    }
}

// Props to Yabai
extension CFString {
    static var kAXExposeShowAllWindows = "AXExposeShowAllWindows" as CFString
    static var kAXExposeShowFrontWindows = "AXExposeShowFrontWindows" as CFString
    static var kAXExposeShowDesktop = "AXExposeShowDesktop" as CFString
    static var kAXExposeExit = "AXExposeExit" as CFString
}
