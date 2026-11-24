import AppKit

/// Outlines the display or window that's the selected source in `ScreenSharePicker`, the way
/// System Settings > Displays highlights a monitor you're pointing at.
@MainActor
final class SelectionHighlightOverlay {
  static let shared = SelectionHighlightOverlay()

  private var window: NSWindow?

  func show(on displayID: CGDirectDisplayID) {
    guard let screen = NSScreen.screens.first(where: {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
    }) else {
      hide()
      return
    }
    place(at: screen.frame)
  }

  /// `frame` is `SCWindow.frame`: global display coordinates with the origin at the upper-left,
  /// same as `CGWindowListCopyWindowInfo`'s bounds, not Cocoa's bottom-left origin.
  func show(window frame: CGRect) {
    place(at: Self.cocoaFrame(forQuartzFrame: frame))
  }

  func hide() {
    window?.orderOut(nil)
  }

  private func place(at frame: CGRect) {
    let overlay = window ?? makeWindow()
    window = overlay
    overlay.setFrame(frame, display: true)
    overlay.orderFrontRegardless()
  }

  private func makeWindow() -> NSWindow {
    let overlay = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    overlay.isOpaque = false
    overlay.backgroundColor = .clear
    overlay.hasShadow = false
    overlay.ignoresMouseEvents = true
    overlay.isReleasedWhenClosed = false
    // Above full-screen apps and the Dock, but shouldn't steal focus from the picker.
    overlay.level = .screenSaver
    overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    overlay.contentView = HighlightBorderView()
    return overlay
  }

  private static func cocoaFrame(forQuartzFrame frame: CGRect) -> CGRect {
    let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
    return CGRect(
      x: frame.origin.x,
      y: mainDisplayHeight - frame.origin.y - frame.height,
      width: frame.width,
      height: frame.height
    )
  }
}

private final class HighlightBorderView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), xRadius: 14, yRadius: 14)
    path.lineWidth = 10
    NSColor.controlAccentColor.setStroke()
    path.stroke()
  }
}
