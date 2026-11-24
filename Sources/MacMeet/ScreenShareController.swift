import AppKit
import ScreenCaptureKit
import WebKit

/// Screen sharing for Meet.
///
/// WKWebView's own `getDisplayMedia` never completes in a third-party app: WebKit accepts the
/// request but neither its ScreenCaptureKit picker nor its older prompt ever appears. Instead, a
/// page script replaces `getDisplayMedia`, MacMeet shows its own picker, captures with
/// ScreenCaptureKit, and streams H.264 frames to the page, which decodes them with WebCodecs into
/// a canvas whose video track goes to Meet.
@MainActor
final class ScreenShareController: NSObject, ObservableObject, WKScriptMessageHandler {
  static let shared = ScreenShareController()
  static let handlerName = "macmeetScreenShare"

  struct Source: Identifiable {
    enum Content {
      case display(SCDisplay)
      case window(SCWindow)
    }

    let id: String
    let title: String
    let subtitle: String
    let icon: NSImage?
    let content: Content
  }

  struct PickerRequest: Identifiable {
    let id = UUID()
    let displays: [Source]
    let windows: [Source]
    let frameRate: Int
  }

  @Published private(set) var pickerRequest: PickerRequest?
  /// Preview images for the current `pickerRequest`'s sources, keyed by `Source.id`, filled in
  /// as each one finishes capturing.
  @Published private(set) var thumbnails: [String: NSImage] = [:]

  weak var webView: WKWebView?
  private var session: ScreenCaptureSession?

  // MARK: - Page script

  static let userScript = WKUserScript(
    source: """
    (() => {
      const post = (message) => window.webkit.messageHandlers.\(handlerName).postMessage(message);
      let pending = null;
      let session = null;

      const requestedFrameRate = (constraints) => {
        const rate = constraints && typeof constraints.video === 'object' ? constraints.video.frameRate : null;
        if (typeof rate === 'number') return rate;
        if (rate && typeof rate === 'object') return rate.ideal || rate.max || rate.exact || 15;
        return 15;
      };

      const fromBase64 = Uint8Array.fromBase64
        ? (base64) => Uint8Array.fromBase64(base64)
        : async (base64) => new Uint8Array(await (await fetch(`data:application/octet-stream;base64,${base64}`)).arrayBuffer());

      const makeDecoder = (current) => new VideoDecoder({
        output(videoFrame) {
          if (session === current) {
            const { canvas, context } = current;
            if (canvas.width !== videoFrame.displayWidth || canvas.height !== videoFrame.displayHeight) {
              canvas.width = videoFrame.displayWidth;
              canvas.height = videoFrame.displayHeight;
            }
            context.drawImage(videoFrame, 0, 0);
          }
          videoFrame.close();
        },
        error() {
          current.decoder = null;
        },
      });

      // Resolves when the decoder takes a frame off its queue, or after a timeout in case it
      // closes or fails first.
      const dequeued = (decoder) => new Promise((resolve) => {
        const done = () => {
          clearTimeout(timer);
          resolve();
        };
        const timer = setTimeout(done, 500);
        decoder.addEventListener('dequeue', done, { once: true });
      });

      const endSession = () => {
        if (!session) return null;
        const ended = session;
        session = null;
        if (ended.decoder && ended.decoder.state !== 'closed') ended.decoder.close();
        ended.stopTrack();
        return ended;
      };

      MediaDevices.prototype.getDisplayMedia = function (constraints) {
        return new Promise((resolve, reject) => {
          if (pending) {
            reject(new DOMException('A screen share request is already in progress.', 'InvalidStateError'));
            return;
          }
          pending = { resolve, reject };
          post({ type: 'request', frameRate: requestedFrameRate(constraints) });
        });
      };

      window.__macmeetScreenShare = {
        started({ width, height, surface, label }) {
          if (!pending) { post({ type: 'stop' }); return; }
          endSession();

          const canvas = document.createElement('canvas');
          canvas.width = width;
          canvas.height = height;
          const context = canvas.getContext('2d');
          const stream = canvas.captureStream();
          const track = stream.getVideoTracks()[0];

          const stopTrack = track.stop.bind(track);
          const getSettings = track.getSettings.bind(track);
          track.stop = () => {
            stopTrack();
            if (session && session.track === track) {
              session = null;
              post({ type: 'stop' });
            }
          };
          track.getSettings = () => ({ ...getSettings(), displaySurface: surface, width: canvas.width, height: canvas.height });
          Object.defineProperty(track, 'label', { value: label });

          session = { canvas, context, track, stopTrack, decoder: null };
          pending.resolve(stream);
          pending = null;
        },

        // Queues one H.264 frame for decoding; the decoder draws it. Resolves once the decoder
        // has room for the next frame, and returns 'keyframe' when the decoder needs to start
        // over from a key frame. (WebKit's decoder holds each frame until the next arrives, so
        // waiting for the draw itself would stall.)
        async frame({ data, key, timestamp, codec, description }) {
          const current = session;
          if (!current) return;
          if (codec) {
            if (current.decoder) current.decoder.close();
            current.decoder = makeDecoder(current);
            current.decoder.configure({ codec, description: await fromBase64(description), optimizeForLatency: true });
          }
          const decoder = current.decoder;
          if (!decoder || decoder.state !== 'configured') return 'keyframe';

          decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp, data: await fromBase64(data) }));
          while (decoder.state === 'configured' && decoder.decodeQueueSize > 2) await dequeued(decoder);
        },

        failed(name, message) {
          if (!pending) return;
          pending.reject(new DOMException(message, name));
          pending = null;
        },

        ended() {
          const ended = endSession();
          if (ended) ended.track.dispatchEvent(new Event('ended'));
        },
      };
    })();
    """,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: true
  )

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
    switch type {
    case "request":
      let frameRate = (body["frameRate"] as? NSNumber)?.intValue ?? 15
      Task { await showPicker(frameRate: min(max(frameRate, 1), 30)) }
    case "stop":
      stopCapture(notifyPage: false)
    default:
      break
    }
  }

  // MARK: - Picker

  private func showPicker(frameRate: Int) async {
    guard CGPreflightScreenCaptureAccess() else {
      // Adds MacMeet to the Screen Recording list in System Settings (and prompts the first time).
      CGRequestScreenCaptureAccess()
      reject("AbortError", "Screen Recording permission is required to share your screen.")
      showPermissionAlert()
      return
    }

    do {
      let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
      let request = PickerRequest(
        displays: content.displays.map(Self.source(for:)),
        windows: content.windows.filter(Self.isShareable).map(Self.source(for:))
          .sorted { ($0.subtitle, $0.title) < ($1.subtitle, $1.title) },
        frameRate: frameRate
      )
      thumbnails = [:]
      pickerRequest = request
      loadThumbnails(for: request)
    } catch {
      reject("NotReadableError", error.localizedDescription)
    }
  }

  /// Captures a still preview of every source in the request, publishing each as it finishes so
  /// the picker can fill thumbnails in progressively rather than waiting on all of them.
  private func loadThumbnails(for request: PickerRequest) {
    for source in request.displays + request.windows {
      Task {
        guard let image = await Self.captureThumbnail(for: source), pickerRequest?.id == request.id else { return }
        thumbnails[source.id] = image
      }
    }
  }

  private static func captureThumbnail(for source: Source) async -> NSImage? {
    let filter: SCContentFilter
    let contentSize: CGSize
    switch source.content {
    case .display(let display):
      filter = SCContentFilter(display: display, excludingWindows: [])
      contentSize = CGSize(width: display.width, height: display.height)
    case .window(let window):
      filter = SCContentFilter(desktopIndependentWindow: window)
      contentSize = window.frame.size
    }

    let size = thumbnailSize(for: contentSize)
    let configuration = SCStreamConfiguration()
    configuration.width = Int(size.width)
    configuration.height = Int(size.height)
    configuration.showsCursor = false
    configuration.scalesToFit = true

    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    else { return nil }
    return NSImage(cgImage: image, size: size)
  }

  /// Scales a source's own size down to a thumbnail no larger than 320×200, preserving aspect ratio.
  private static func thumbnailSize(for contentSize: CGSize) -> CGSize {
    let maxSize = CGSize(width: 320, height: 200)
    guard contentSize.width > 0, contentSize.height > 0 else { return maxSize }
    let scale = min(maxSize.width / contentSize.width, maxSize.height / contentSize.height, 1)
    return CGSize(
      width: max(2, (contentSize.width * scale).rounded()),
      height: max(2, (contentSize.height * scale).rounded())
    )
  }

  func share(_ source: Source) {
    guard let request = pickerRequest else { return }
    pickerRequest = nil
    thumbnails = [:]
    stopCapture(notifyPage: false)

    let filter: SCContentFilter
    let surface: String
    switch source.content {
    case .display(let display):
      filter = SCContentFilter(display: display, excludingWindows: [])
      surface = "monitor"
    case .window(let window):
      filter = SCContentFilter(desktopIndependentWindow: window)
      surface = "window"
    }

    let session = ScreenCaptureSession(
      filter: filter,
      frameRate: request.frameRate,
      onFrame: { session, frame in
        Task { @MainActor in ScreenShareController.shared.deliver(frame, from: session) }
      },
      onStop: { session in
        Task { @MainActor in ScreenShareController.shared.captureEnded(session) }
      }
    )
    self.session = session

    Task {
      do {
        try await session.start()
        guard self.session === session else {
          session.stop()
          return
        }
        let details: [String: Any] = [
          "width": session.size.width,
          "height": session.size.height,
          "surface": surface,
          "label": source.title,
        ]
        callPage("started", details)
      } catch {
        if self.session === session { self.session = nil }
        reject("NotReadableError", error.localizedDescription)
      }
    }
  }

  func cancelPicker() {
    guard pickerRequest != nil else { return }
    pickerRequest = nil
    thumbnails = [:]
    // Meet treats a request as cancelled by the user only when it fails the way Safari's does:
    // a NotAllowedError with exactly WebKit's message. Any other error makes it show "Something
    // went wrong" or its permission instructions.
    reject(
      "NotAllowedError",
      "The request is not allowed by the user agent or the platform in the current context, possibly because the user denied permission."
    )
  }

  /// A navigation replaces the page, and with it the script's state, so drop any share.
  func pageDidNavigate() {
    pickerRequest = nil
    thumbnails = [:]
    stopCapture(notifyPage: false)
  }

  // MARK: - Capture

  private func deliver(_ frame: ScreenCaptureSession.EncodedFrame, from session: ScreenCaptureSession) {
    guard self.session === session, let webView else {
      session.frameDelivered()
      return
    }
    // Passing the frame as an argument spares the page from parsing it as script source, and
    // awaiting the draw means the next frame is captured only once the page is ready for it.
    webView.callAsyncJavaScript(
      "return await window.__macmeetScreenShare.frame(frame)",
      arguments: ["frame": frame.dictionary],
      in: nil,
      in: .page
    ) { result in
      if case .success(let value) = result, value as? String == "keyframe" {
        session.requestKeyFrame()
      }
      session.frameDelivered()
    }
  }

  private func captureEnded(_ session: ScreenCaptureSession) {
    guard self.session === session else { return }
    stopCapture(notifyPage: true)
  }

  private func stopCapture(notifyPage: Bool) {
    guard let session else { return }
    self.session = nil
    session.stop()
    if notifyPage { callPage("ended") }
  }

  // MARK: - Helpers

  /// Meet answers a `NotAllowedError` with instructions for Safari's per-site settings, which
  /// don't apply here, so refusals other than a cancelled picker use `AbortError` instead.
  private func reject(_ name: String, _ message: String) {
    callPage("failed", name, message)
  }

  private func callPage(_ function: String, _ arguments: Any...) {
    guard let data = try? JSONSerialization.data(withJSONObject: arguments),
          let json = String(data: data, encoding: .utf8) else { return }
    webView?.evaluateJavaScript("window.__macmeetScreenShare.\(function)(...\(json))")
  }

  private func showPermissionAlert() {
    let alert = NSAlert()
    alert.messageText = "Allow MacMeet to record your screen"
    alert.informativeText = """
      To share your screen, turn on MacMeet in System Settings > Privacy & Security > \
      Screen & System Audio Recording, then quit and reopen MacMeet.
      """
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn,
       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
      NSWorkspace.shared.open(url)
    }
  }

  private static func isShareable(_ window: SCWindow) -> Bool {
    guard let app = window.owningApplication, window.isOnScreen, window.windowLayer == 0 else { return false }
    return app.bundleIdentifier != Bundle.main.bundleIdentifier
      && window.frame.width >= 100
      && window.frame.height >= 100
  }

  private static func source(for display: SCDisplay) -> Source {
    let screen = NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
    }
    return Source(
      id: "display-\(display.displayID)",
      title: screen?.localizedName ?? "Display",
      subtitle: "\(display.width) × \(display.height)",
      icon: nil,
      content: .display(display)
    )
  }

  private static func source(for window: SCWindow) -> Source {
    let appName = window.owningApplication?.applicationName ?? ""
    let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? appName
    let icon = window.owningApplication
      .flatMap { NSRunningApplication(processIdentifier: $0.processID) }?.icon
    return Source(
      id: "window-\(window.windowID)",
      title: title,
      subtitle: appName,
      icon: icon,
      content: .window(window)
    )
  }
}
