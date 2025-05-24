//
//  MenuBarOverlayPanel.swift
//  Ice
//

import Cocoa
import Combine

// MARK: - Overlay Panel

/// A subclass of `NSPanel` that sits atop the menu bar to alter its appearance.
final class MenuBarOverlayPanel: NSPanel {
    /// Flags representing the updatable components of a panel.
    enum UpdateFlag: String, CustomStringConvertible {
        case applicationMenuFrame
        case desktopWallpaper

        var description: String { rawValue }
    }

    /// The kind of validation that occurs before an update.
    private enum ValidationKind {
        case showing
        case updates
    }

    /// A context that manages panel update tasks.
    final class UpdateTaskContext {
        private var tasks = [UpdateFlag: Task<Void, any Error>]()

        /// Sets the task for the given update flag.
        ///
        /// Setting the task cancels the previous task for the flag, if there is one.
        ///
        /// - Parameters:
        ///   - flag: The update flag to set the task for.
        ///   - timeout: The timeout of the task.
        ///   - operation: The operation for the task to perform.
        func setTask(for flag: UpdateFlag, timeout: Duration, operation: @escaping () async throws -> Void) {
            cancelTask(for: flag)
            tasks[flag] = Task.detached(timeout: timeout) {
                try await operation()
            }
        }

        /// Cancels the task for the given update flag.
        ///
        /// - Parameter flag: The update flag to cancel the task for.
        func cancelTask(for flag: UpdateFlag) {
            tasks.removeValue(forKey: flag)?.cancel()
        }
    }

    /// A Boolean value that indicates whether the panel needs to be shown.
    @Published var needsShow = false

    /// Flags representing the components of the panel currently in need of an update.
    @Published private(set) var updateFlags = Set<UpdateFlag>()

    /// The frame of the application menu.
    @Published private(set) var applicationMenuFrame: CGRect?

    /// The current desktop wallpaper, clipped to the bounds of the menu bar.
    @Published private(set) var desktopWallpaper: CGImage?

    /// The space that the panel is present on.
    var space: Int

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The context that manages panel update tasks.
    let updateTaskContext = UpdateTaskContext()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The screen that owns the panel.
    let owningScreen: NSScreen

    /// Creates an overlay panel with the given app state and owning screen.
    init(appState: AppState, owningScreen: NSScreen, onSpace space: Int) {
        self.appState = appState
        self.owningScreen = owningScreen
        self.space = space
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .statusBar
        self.title = "Menu Bar Overlay"
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.fullScreenNone, .ignoresCycle, .stationary]
        self.contentView = MenuBarOverlayPanelContentView()
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()
        $needsShow
            .debounce(for: 0.05, scheduler: DispatchQueue.main)
            .sink { [weak self] needsShow in
                guard let self, needsShow else {
                    return
                }
                defer {
                    self.needsShow = false
                }
                show()
            }
            .store(in: &c)

        $updateFlags
            .sink { [weak self] flags in
                guard let self, !flags.isEmpty else { return }
                Task {
                    // Must be run async, or this will not remove the flags.
                    self.updateFlags.removeAll()
                }
                let windows = WindowInfo.getOnScreenWindows()
                guard let owningDisplay = validate(for: .updates, with: windows) else {
                    return
                }
                performUpdates(for: flags, windows: windows, display: owningDisplay)
            }
            .store(in: &c)

        cancellables = c
    }

    /// Inserts the given update flag into the panel's current list of update flags.
    func insertUpdateFlag(_ flag: UpdateFlag) {
        updateFlags.insert(flag)
    }

    /// Performs validation for the given validation kind. Returns the panel's
    /// owning display if successful. Returns `nil` on failure.
    private func validate(for kind: ValidationKind, with windows: [WindowInfo]) -> CGDirectDisplayID? {
        lazy var actionMessage =
            switch kind {
            case .showing: "Preventing overlay panel from showing."
            case .updates: "Preventing overlay panel from updating."
            }
        guard let appState else {
            Logger.overlayPanel.debug("No app state. \(actionMessage)")
            return nil
        }
        guard !appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults else {
            Logger.overlayPanel.debug("Menu bar is hidden by system. \(actionMessage)")
            return nil
        }
        guard !appState.isActiveSpaceFullscreen else {
            Logger.overlayPanel.debug("Active space is fullscreen. \(actionMessage)")
            return nil
        }
        let owningDisplay = owningScreen.displayID
        guard appState.menuBarManager.hasValidMenuBar(in: windows, for: owningDisplay) else {
            //            Logger.overlayPanel.debug("No valid menu bar found. \(actionMessage)")
            return nil
        }
        return owningDisplay
    }

    /// Stores the frame of the menu bar's application menu.
    private func updateApplicationMenuFrame(for display: CGDirectDisplayID) {
        guard
            let menuBarManager = appState?.menuBarManager,
            !menuBarManager.isMenuBarHiddenBySystem
        else {
            return
        }
        applicationMenuFrame = menuBarManager.getApplicationMenuFrame(for: display)
    }

    /// Stores the area of the desktop wallpaper that is under the menu bar
    /// of the given display.
    private func updateDesktopWallpaper(for display: CGDirectDisplayID, with windows: [WindowInfo]) {
        guard
            let wallpaperWindow = WindowInfo.getWallpaperWindow(from: windows, for: display),
            let menuBarWindow = WindowInfo.getMenuBarWindow(from: windows, for: display)
        else { return }
        let wallpaper = ScreenCapture.captureWindow(wallpaperWindow.windowID, screenBounds: menuBarWindow.frame)
        if desktopWallpaper?.dataProvider?.data != wallpaper?.dataProvider?.data {
            desktopWallpaper = wallpaper
        }
    }

    /// Updates the panel to prepare for display.
    private func performUpdates(for flags: Set<UpdateFlag>, windows: [WindowInfo], display: CGDirectDisplayID) {
        if flags.contains(.applicationMenuFrame) { updateApplicationMenuFrame(for: display) }
        if flags.contains(.desktopWallpaper) { updateDesktopWallpaper(for: display, with: windows) }
    }

    /// Shows the panel.
    private func show() {
        guard
            let appState,
            !appState.isPreview
        else {
            return
        }

        guard appState.appearanceManager.overlayPanels.values.contains(self) else {
            Logger.overlayPanel.warning("Overlay panel \(self) not retained")
            return
        }

        guard let menuBarHeight = owningScreen.getMenuBarHeight() else {
            return
        }

        let newFrame = CGRect(
            x: owningScreen.frame.minX,
            y: (owningScreen.frame.maxY - menuBarHeight) - 5,
            width: owningScreen.frame.width,
            height: menuBarHeight + 5
        )

        alphaValue = 0
        setFrame(newFrame, display: false)
        orderFrontRegardless()

        updateFlags = [.applicationMenuFrame, .desktopWallpaper]

        if !appState.menuBarManager.isMenuBarHiddenBySystem {
            animator().alphaValue = 1
        }
    }

    override func isAccessibilityElement() -> Bool {
        return false
    }
}

// MARK: - Content View

private final class MenuBarOverlayPanelContentView: NSView {
    @Published private var fullConfiguration: MenuBarAppearanceConfigurationV2 = .defaultConfiguration

    @Published private var previewConfiguration: MenuBarAppearancePartialConfiguration?

    private var cancellables = Set<AnyCancellable>()

    /// The overlay panel that contains the content view.
    private var overlayPanel: MenuBarOverlayPanel? {
        window as? MenuBarOverlayPanel
    }

    /// The currently displayed configuration.
    private var configuration: MenuBarAppearancePartialConfiguration {
        previewConfiguration ?? fullConfiguration.current
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        guard let overlayPanel else { return }

        if let appState = overlayPanel.appState {
            appState.appearanceManager.$configuration
                .removeDuplicates()
                .assign(to: &$fullConfiguration)

            appState.appearanceManager.$previewConfiguration
                .removeDuplicates()
                .assign(to: &$previewConfiguration)

            for section in appState.menuBarManager.sections {
                // Redraw whenever the window frame of a control item changes.
                //
                // - NOTE: A previous attempt was made to redraw the view when the section's `isHidden` property was changed. This would be semantically
                //   ideal, but the property sometimes changes before the menu bar items are actually updated on-screen. Since the view's drawing process relies
                //   on getting an accurate position of each menu bar item, we need to use something that publishes its changes only after the items are updated.
                section.controlItem.$windowFrame
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        self?.needsDisplay = true
                    }
                    .store(in: &c)

                // Redraw whenever the visibility of a control item changes.
                //
                // - NOTE: If the "ShowSectionDividers" setting is disabled, the window
                //   frame does not update when the section is hidden or shown, but the
                //   visibility does. We observe both to ensure the update occurs.
                section.controlItem.$isVisible
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        self?.needsDisplay = true
                    }
                    .store(in: &c)
            }
        }

        // Cut out whenever a menu bar item is being dragged or mission control is active.
        AppState.shared.appearanceManager.$hideOverlaypanels
            .removeDuplicates()
            .sink { [weak self] hide in
                self?.alphaValue = hide ? 0 : 1
            }
            .store(in: &c)
        // Redraw whenever the application menu frame changes.
        overlayPanel.$applicationMenuFrame
            .sink { [weak self] _ in
                self?.needsDisplay = true
            }
            .store(in: &c)
        // Redraw whenever the desktop wallpaper changes.
        overlayPanel.$desktopWallpaper
            .sink { [weak self] _ in
                self?.needsDisplay = true
            }
            .store(in: &c)

        // Redraw whenever the configurations change.
        $fullConfiguration.mapToVoid()
            .merge(with: $previewConfiguration.mapToVoid())
            .sink { [weak self] _ in
                self?.needsDisplay = true
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a path in the given rectangle, with the given end caps,
    /// and inset by the given amounts.
    private func shapePath(
        in rect: CGRect,
        leadingEndCap: MenuBarEndCap,
        trailingEndCap: MenuBarEndCap,
        screen: NSScreen
    ) -> NSBezierPath {
        let insetRect: CGRect =
            if !screen.hasNotch {
                switch (leadingEndCap, trailingEndCap) {
                case (.square, .square):
                    CGRect(x: rect.origin.x, y: rect.origin.y + 1, width: rect.width, height: rect.height - 2)
                case (.square, .round):
                    CGRect(x: rect.origin.x, y: rect.origin.y + 1, width: rect.width - 1, height: rect.height - 2)
                case (.round, .square):
                    CGRect(x: rect.origin.x + 1, y: rect.origin.y + 1, width: rect.width - 1, height: rect.height - 2)
                case (.round, .round):
                    CGRect(x: rect.origin.x + 1, y: rect.origin.y + 1, width: rect.width - 2, height: rect.height - 2)
                }
            } else {
                rect
            }

        let shapeBounds = CGRect(
            x: insetRect.minX + insetRect.height / 2,
            y: insetRect.minY,
            width: insetRect.width - insetRect.height,
            height: insetRect.height
        )
        let leadingEndCapBounds = CGRect(
            x: insetRect.minX,
            y: insetRect.minY,
            width: insetRect.height,
            height: insetRect.height
        )
        let trailingEndCapBounds = CGRect(
            x: insetRect.maxX - insetRect.height,
            y: insetRect.minY,
            width: insetRect.height,
            height: insetRect.height
        )

        var path = NSBezierPath(rect: shapeBounds)

        path =
            switch leadingEndCap {
            case .square: path.union(NSBezierPath(rect: leadingEndCapBounds))
            case .round: path.union(NSBezierPath(ovalIn: leadingEndCapBounds))
            }

        path =
            switch trailingEndCap {
            case .square: path.union(NSBezierPath(rect: trailingEndCapBounds))
            case .round: path.union(NSBezierPath(ovalIn: trailingEndCapBounds))
            }

        return path
    }

    /// Returns a path for the ``MenuBarShapeKind/full`` shape kind.
    private func pathForFullShape(in rect: CGRect, info: MenuBarFullShapeInfo, isInset: Bool, screen: NSScreen)
        -> NSBezierPath
    {
        guard let appearanceManager = overlayPanel?.appState?.appearanceManager else {
            return NSBezierPath()
        }
        var rect = rect
        let shouldInset = isInset && screen.hasNotch
        if shouldInset {
            rect = rect.insetBy(dx: 0, dy: appearanceManager.menuBarInsetAmount)
            if info.leadingEndCap == .round {
                rect.origin.x += appearanceManager.menuBarInsetAmount
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
            if info.trailingEndCap == .round {
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
        }
        return shapePath(
            in: rect,
            leadingEndCap: info.leadingEndCap,
            trailingEndCap: info.trailingEndCap,
            screen: screen
        )
    }

    /// Returns a path for the ``MenuBarShapeKind/split`` shape kind.
    private func pathForSplitShape(in rect: CGRect, info: MenuBarSplitShapeInfo, isInset: Bool, screen: NSScreen)
        -> NSBezierPath
    {
        guard let appearanceManager = overlayPanel?.appState?.appearanceManager else {
            return NSBezierPath()
        }
        var rect = rect
        let shouldInset = isInset && screen.hasNotch
        if shouldInset {
            rect = rect.insetBy(dx: 0, dy: appearanceManager.menuBarInsetAmount)
            if info.leading.leadingEndCap == .round {
                rect.origin.x += appearanceManager.menuBarInsetAmount
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
            if info.trailing.trailingEndCap == .round {
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
        }
        let leadingPathBounds: CGRect = {
            guard
                var maxX = overlayPanel?.applicationMenuFrame?.width,
                maxX > 0
            else {
                return .zero
            }
            if shouldInset {
                maxX += 10
                if info.leading.leadingEndCap == .square {
                    maxX += appearanceManager.menuBarInsetAmount
                }
            } else {
                maxX += 20
            }
            return CGRect(x: rect.minX, y: rect.minY, width: maxX, height: rect.height)
        }()
        let trailingPathBounds: CGRect = {
            let items = MenuBarItem.getMenuBarItems(on: screen.displayID, onScreenOnly: true, activeSpaceOnly: false)
            guard !items.isEmpty else {
                return .zero
            }
            let totalWidth = items.reduce(into: 0) { width, item in
                width += item.frame.width
            }
            var position = rect.maxX - totalWidth
            if shouldInset {
                position += 4
                if info.trailing.trailingEndCap == .square {
                    position -= appearanceManager.menuBarInsetAmount
                }
            } else {
                position -= 7
            }
            return CGRect(x: position, y: rect.minY, width: rect.maxX - position, height: rect.height)
        }()

        if leadingPathBounds == .zero || trailingPathBounds == .zero || leadingPathBounds.intersects(trailingPathBounds)
        {
            return shapePath(
                in: rect,
                leadingEndCap: info.leading.leadingEndCap,
                trailingEndCap: info.trailing.trailingEndCap,
                screen: screen
            )
        } else {
            let leadingPath = shapePath(
                in: leadingPathBounds,
                leadingEndCap: info.leading.leadingEndCap,
                trailingEndCap: info.leading.trailingEndCap,
                screen: screen
            )
            let trailingPath = shapePath(
                in: trailingPathBounds,
                leadingEndCap: info.trailing.leadingEndCap,
                trailingEndCap: info.trailing.trailingEndCap,
                screen: screen
            )
            let path = NSBezierPath()
            path.append(leadingPath)
            path.append(trailingPath)
            return path
        }
    }

    /// Returns the bounds that the view's drawn content can occupy.
    private func getDrawableBounds() -> CGRect {
        return CGRect(
            x: bounds.origin.x,
            y: bounds.origin.y + 5,
            width: bounds.width,
            height: bounds.height - 5
        )
    }

    /// Draws the tint defined by the given configuration in the given rectangle.
    private func drawTint(in rect: CGRect) {
        switch configuration.tintKind {
        case .none:
            break
        case .solid:
            if let tintColor = NSColor(cgColor: configuration.tintColor)?.withAlphaComponent(0.2) {
                tintColor.setFill()
                rect.fill()
            }
        case .gradient:
            if let tintGradient = configuration.tintGradient.withAlphaComponent(0.2).nsGradient {
                tintGradient.draw(in: rect, angle: 0)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard
            let overlayPanel,
            let context = NSGraphicsContext.current
        else {
            return
        }

        let drawableBounds = getDrawableBounds()

        let shapePath =
            switch fullConfiguration.shapeKind {
            case .none:
                NSBezierPath(rect: drawableBounds)
            case .full:
                pathForFullShape(
                    in: drawableBounds,
                    info: fullConfiguration.fullShapeInfo,
                    isInset: fullConfiguration.isInset,
                    screen: overlayPanel.owningScreen
                )
            case .split:
                pathForSplitShape(
                    in: drawableBounds,
                    info: fullConfiguration.splitShapeInfo,
                    isInset: fullConfiguration.isInset,
                    screen: overlayPanel.owningScreen
                )
            }

        var hasBorder = false

        switch fullConfiguration.shapeKind {
        case .none:
            if configuration.hasShadow {
                let gradient = NSGradient(
                    colors: [NSColor(white: 0.0, alpha: 0.0), NSColor(white: 0.0, alpha: 0.2)]
                )
                let shadowBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: 5
                )
                gradient?.draw(in: shadowBounds, angle: 90)
            }

            drawTint(in: drawableBounds)

            if configuration.hasBorder {
                let borderBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY + 5,
                    width: bounds.width,
                    height: configuration.borderWidth
                )
                NSColor(cgColor: configuration.borderColor)?.setFill()
                NSBezierPath(rect: borderBounds).fill()
            }
        case .full, .split:
            if let desktopWallpaper = overlayPanel.desktopWallpaper {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                let invertedClipPath = NSBezierPath(rect: drawableBounds)
                invertedClipPath.append(shapePath.reversed)
                invertedClipPath.setClip()

                context.cgContext.draw(desktopWallpaper, in: drawableBounds)
            }

            if configuration.hasShadow {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                let shadowClipPath = NSBezierPath(rect: bounds)
                shadowClipPath.append(shapePath.reversed)
                shadowClipPath.setClip()

                shapePath.drawShadow(color: .black.withAlphaComponent(0.5), radius: 5)
            }

            if configuration.hasBorder {
                hasBorder = true
            }

            do {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                shapePath.setClip()

                drawTint(in: drawableBounds)
            }

            if hasBorder,
                let borderColor = NSColor(cgColor: configuration.borderColor)
            {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                let borderPath =
                    switch fullConfiguration.shapeKind {
                    case .none:
                        NSBezierPath(rect: drawableBounds)
                    case .full:
                        pathForFullShape(
                            in: drawableBounds,
                            info: fullConfiguration.fullShapeInfo,
                            isInset: fullConfiguration.isInset,
                            screen: overlayPanel.owningScreen
                        )
                    case .split:
                        pathForSplitShape(
                            in: drawableBounds,
                            info: fullConfiguration.splitShapeInfo,
                            isInset: fullConfiguration.isInset,
                            screen: overlayPanel.owningScreen
                        )
                    }

                // HACK: Insetting a path to get an "inside" stroke is surprisingly
                // difficult. We can fake the correct line width by doubling it, as
                // anything outside the shape path will be clipped.
                borderPath.lineWidth = configuration.borderWidth * 2
                borderPath.setClip()

                borderColor.setStroke()
                borderPath.stroke()
            }
        }
    }
}

// MARK: - Logger
extension Logger {
    fileprivate static let overlayPanel = Logger(category: "MenuBarOverlayPanel")
}
