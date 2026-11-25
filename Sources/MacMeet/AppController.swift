import AppKit
import KeyboardShortcuts
import SwiftUI

/// Owns the main window and the preferences that decide what happens when it closes: quit, or
/// keep running with a Dock icon, a menu bar item, or both.
@MainActor
final class AppController: NSObject, ObservableObject {
  static let shared = AppController()

  enum CloseBehavior: String, CaseIterable, Identifiable {
    case quit
    case keepRunning

    var id: Self { self }
  }

  private enum Key {
    static let closeBehavior = "closeBehavior"
    static let keepInDock = "keepInDock"
    static let keepInMenuBar = "keepInMenuBar"
    static let useSystemWideHotkeys = "useSystemWideHotkeys"
    static let asksBeforeLeavingOnClose = "asksBeforeLeavingOnClose"
    static let muteMicrophoneOnJoin = "muteMicrophoneOnJoin"
    static let turnOffCameraOnJoin = "turnOffCameraOnJoin"
  }

  private let defaults = UserDefaults.standard

  @Published var closeBehavior: CloseBehavior {
    didSet {
      defaults.set(closeBehavior.rawValue, forKey: Key.closeBehavior)
      applyPresence()
    }
  }

  @Published var keepInDock: Bool {
    didSet {
      defaults.set(keepInDock, forKey: Key.keepInDock)
      applyPresence()
    }
  }

  @Published var keepInMenuBar: Bool {
    didSet { defaults.set(keepInMenuBar, forKey: Key.keepInMenuBar) }
  }

  /// Records links and navigations to `DebugLog.fileURL` for troubleshooting.
  @Published var debugLogging: Bool {
    didSet {
      defaults.set(debugLogging, forKey: DebugLog.enabledKey)
      DebugLog.write("Debug logging enabled, version \(Self.version)")
    }
  }

  /// Lets the mic/camera toggle shortcuts work even when MacMeet isn't the frontmost app.
  @Published var useSystemWideHotkeys: Bool {
    didSet { defaults.set(useSystemWideHotkeys, forKey: Key.useSystemWideHotkeys) }
  }

  /// Asks before closing the main window disconnects a call. When off, closing the window leaves
  /// the call right away.
  @Published var asksBeforeLeavingOnClose: Bool {
    didSet { defaults.set(asksBeforeLeavingOnClose, forKey: Key.asksBeforeLeavingOnClose) }
  }

  /// Mutes the microphone on Meet's pre-join screen before every meeting is joined.
  @Published var muteMicrophoneOnJoin: Bool {
    didSet { defaults.set(muteMicrophoneOnJoin, forKey: Key.muteMicrophoneOnJoin) }
  }

  /// Turns off the camera on Meet's pre-join screen before every meeting is joined.
  @Published var turnOffCameraOnJoin: Bool {
    didSet { defaults.set(turnOffCameraOnJoin, forKey: Key.turnOffCameraOnJoin) }
  }

  /// Set while closing the window quits the app, so applicationShouldTerminate can skip its prompt
  /// when `asksBeforeLeavingOnClose` is off.
  private(set) var isQuittingFromWindowClose = false

  @Published var showingJoinSheet = false
  @Published private(set) var isWindowVisible = false

  /// Hiding the Dock icon forces the menu bar item on, so a running MacMeet is always reachable.
  var effectiveKeepInMenuBar: Bool { keepInMenuBar || !keepInDock }

  var showsMenuBarItem: Bool {
    isWindowVisible || (closeBehavior == .keepRunning && effectiveKeepInMenuBar)
  }

  private var showsDockIcon: Bool {
    isWindowVisible || closeBehavior == .quit || keepInDock
  }

  private lazy var window = makeWindow()

  override init() {
    defaults.register(defaults: [
      Key.closeBehavior: CloseBehavior.keepRunning.rawValue,
      Key.keepInDock: true,
      Key.keepInMenuBar: true,
      Key.useSystemWideHotkeys: false,
      Key.asksBeforeLeavingOnClose: true,
      Key.muteMicrophoneOnJoin: false,
      Key.turnOffCameraOnJoin: false,
    ])
    closeBehavior = CloseBehavior(rawValue: defaults.string(forKey: Key.closeBehavior) ?? "") ?? .keepRunning
    keepInDock = defaults.bool(forKey: Key.keepInDock)
    keepInMenuBar = defaults.bool(forKey: Key.keepInMenuBar)
    debugLogging = defaults.bool(forKey: DebugLog.enabledKey)
    useSystemWideHotkeys = defaults.bool(forKey: Key.useSystemWideHotkeys)
    asksBeforeLeavingOnClose = defaults.bool(forKey: Key.asksBeforeLeavingOnClose)
    muteMicrophoneOnJoin = defaults.bool(forKey: Key.muteMicrophoneOnJoin)
    turnOffCameraOnJoin = defaults.bool(forKey: Key.turnOffCameraOnJoin)
    super.init()

    KeyboardShortcuts.onKeyDown(for: .toggleMicrophone) { [weak self] in
      guard self?.useSystemWideHotkeys == true else { return }
      MeetController.shared.toggleMicrophone()
    }
    KeyboardShortcuts.onKeyDown(for: .toggleCamera) { [weak self] in
      guard self?.useSystemWideHotkeys == true else { return }
      MeetController.shared.toggleCamera()
    }

    // See showWindow. By the time the user switches away, the window has settled on its Space.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { _ = self?.window.collectionBehavior.remove(.moveToActiveSpace) }
    }
  }

  // MARK: - Actions

  func showWindow() {
    // A hidden window remembers the Space it was closed on. Bring it to the current Space
    // instead, and drop this once the app resigns active so a visible window stays where the user
    // puts it. Dropping it any sooner is too early when the app is already active, as it is when
    // another app hands it a meeting link: the window becomes key as it's ordered in, before it
    // has moved, and stays on its old Space.
    if !window.isVisible {
      window.collectionBehavior.insert(.moveToActiveSpace)
    }
    DebugLog.write("Showing window (visible: \(window.isVisible), app active: \(NSApp.isActive))")
    isWindowVisible = true
    applyPresence()
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    // An inactive app (running from the menu bar, or with its Dock icon just restored) may not
    // be activated until later, and makeKeyAndOrderFront alone leaves its window behind the
    // active app's. Raise the window over every app's windows regardless.
    window.orderFrontRegardless()
    DispatchQueue.main.async { [window] in
      DebugLog.write("Window shown, on the current Space: \(window.isOnActiveSpace)")
    }
  }

  func newMeeting() {
    showWindow()
    MeetController.shared.newMeeting()
  }

  func goHome() {
    showWindow()
    MeetController.shared.goHome()
  }

  func showJoinSheet() {
    showWindow()
    showingJoinSheet = true
  }

  static let homepage = URL(string: "https://github.com/jsumners-nr/macmeet")!

  static var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
  }

  func showDebugLog() {
    if FileManager.default.fileExists(atPath: DebugLog.fileURL.path()) {
      NSWorkspace.shared.activateFileViewerSelecting([DebugLog.fileURL])
    } else {
      NSWorkspace.shared.open(DebugLog.fileURL.deletingLastPathComponent().deletingLastPathComponent())
    }
  }

  /// The standard About panel, with the build's version and a link to the project's repository.
  func showAbout() {
    let version = Self.version

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph,
    ]
    let credits = NSMutableAttributedString(string: "A native macOS app for Google Meet.\n", attributes: attributes)
    var linkAttributes = attributes
    linkAttributes[.link] = Self.homepage
    credits.append(NSAttributedString(string: "github.com/jsumners-nr/macmeet", attributes: linkAttributes))

    // Without a Dock icon the app isn't active, so the panel would open behind other apps.
    NSApp.activate()
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationVersion: version,
      // An empty build version keeps the panel from appending "(20261119.5)".
      .version: "",
      .credits: credits,
    ])
  }

  // MARK: - Window

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
      styleMask: [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
      ],
      backing: .buffered,
      defer: false
    )
    let hostingView = NSHostingView(rootView: ContentView())
    hostingView.sceneBridgingOptions = [.toolbars, .title]
    window.contentView = hostingView
    window.contentMinSize = NSSize(width: 800, height: 560)
    window.toolbarStyle = .unifiedCompact
    window.tabbingMode = .disallowed
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    window.setFrameAutosaveName("MainWindow")
    return window
  }

  /// Shows or hides the Dock icon. The menu bar item follows `showsMenuBarItem` on its own.
  private func applyPresence() {
    let policy: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
    if NSApp.activationPolicy() != policy {
      NSApp.setActivationPolicy(policy)
    }
  }
}

extension AppController: NSWindowDelegate {
  /// Closing the window ends any meeting. Then the app either quits or hides the window and
  /// waits in the background until it's reopened or handed a meeting link.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    switch closeBehavior {
    case .quit:
      // applicationShouldTerminate asks before leaving a meeting, unless that's turned off.
      isQuittingFromWindowClose = true
      NSApp.terminate(nil)
      isQuittingFromWindowClose = false
    case .keepRunning:
      guard !asksBeforeLeavingOnClose || Self.confirmLeavingMeeting(
        because: "Closing the window will disconnect you from the current call.",
        confirmTitle: "Leave"
      ) else { break }
      MeetController.shared.leaveMeeting()
      sender.orderOut(nil)
      isWindowVisible = false
      applyPresence()
    }
    return false
  }

  /// Returns true when there's no meeting to leave, or the user agrees to leave it.
  static func confirmLeavingMeeting(because reason: String, confirmTitle: String) -> Bool {
    guard MeetController.shared.isInCall else { return true }

    let alert = NSAlert()
    alert.messageText = "Leave the meeting?"
    alert.informativeText = reason
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }
}
