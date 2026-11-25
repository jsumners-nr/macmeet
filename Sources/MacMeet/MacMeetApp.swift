import AppKit
import SwiftUI

@main
struct MacMeetApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @ObservedObject private var app = AppController.shared

  private var meet: MeetController { .shared }

  var body: some Scene {
    // The main window is an AppKit window owned by AppController, so closing it can hide it
    // instead of tearing down the web view.
    MenuBarExtra(isInserted: Binding(get: { app.showsMenuBarItem }, set: { _ in })) {
      MenuBarMenu()
    } label: {
      MenuBarLabel()
    }

    Settings {
      SettingsView()
    }
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About MacMeet") { app.showAbout() }
      }

      CommandGroup(replacing: .newItem) {
        Button("New Meeting") { app.newMeeting() }
          .keyboardShortcut("n")
        Button("Join Meeting…") { app.showJoinSheet() }
          .keyboardShortcut("j")
        Divider()
        Button("Meet Home") { app.goHome() }
          .keyboardShortcut("h", modifiers: [.command, .shift])
      }

      CommandMenu("Meeting") {
        Button("Toggle Microphone") { meet.toggleMicrophone() }
          .keyboardShortcut("d")
        Button("Toggle Camera") { meet.toggleCamera() }
          .keyboardShortcut("e")
        Divider()
        Button("Copy Meeting Link") { meet.copyMeetingLink() }
          .keyboardShortcut("c", modifiers: [.command, .shift])
      }

      CommandGroup(after: .toolbar) {
        Button("Reload Page") { meet.reload() }
          .keyboardShortcut("r")
        Divider()
      }

      CommandGroup(before: .windowList) {
        Button("MacMeet") { app.showWindow() }
          .keyboardShortcut("0")
        Divider()
      }
    }
  }
}

struct ContentView: View {
  @ObservedObject private var meet = MeetController.shared
  @ObservedObject private var app = AppController.shared
  @ObservedObject private var screenShare = ScreenShareController.shared
  @ObservedObject private var joinMonitor = JoinMonitor.shared

  /// Dismissing the picker any way other than Share counts as cancelling.
  private var screenSharePicker: Binding<ScreenShareController.PickerRequest?> {
    Binding(
      get: { screenShare.pickerRequest },
      set: { if $0 == nil { screenShare.cancelPicker() } }
    )
  }

  var body: some View {
    MeetWebView(webView: meet.webView)
      .ignoresSafeArea()
      .overlay {
        if joinMonitor.isJoining { JoiningOverlay() }
      }
      .animation(.easeInOut(duration: 0.2), value: joinMonitor.isJoining)
      .navigationTitle(meet.title)
      .navigationSubtitle(meet.meetingCode ?? "")
      .toolbar {
        ToolbarItemGroup(placement: .navigation) {
          Button { meet.goHome() } label: { Label("Home", systemImage: "house") }
        }
        ToolbarItemGroup(placement: .primaryAction) {
          Menu {
            Button("Copy Meeting Link") { meet.copyMeetingLink() }
            if let link = meet.meetingLink {
              ShareLink("Share", item: link)
            }
          } label: {
            Label("Share", systemImage: "square.and.arrow.up")
          }
          .disabled(!meet.isInCall)
          .help("Share the meeting link")
          Button { meet.newMeeting() } label: { Label("New Meeting", systemImage: "video.badge.plus") }
            .help("Start a new meeting")
          Button { app.showingJoinSheet = true } label: { Label("Join", systemImage: "link") }
            .help("Join a meeting by code or link")
        }
      }
      .sheet(isPresented: $app.showingJoinSheet) {
        JoinMeetingView { code in meet.join(code) }
      }
      .sheet(item: screenSharePicker) { request in
        switch app.screenSharePickerStyle {
        case .previews:
          ScreenSharePicker(
            request: request,
            onShare: { screenShare.share($0) },
            onCancel: { screenShare.cancelPicker() }
          )
        case .list:
          ScreenShareListPicker(
            request: request,
            onShare: { screenShare.share($0) },
            onCancel: { screenShare.cancelPicker() }
          )
        }
      }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  @MainActor
  func applicationDidFinishLaunching(_ notification: Notification) {
    DebugLog.write("Finished launching")
    NotificationBridge.requestAuthorization()
    AppController.shared.showWindow()
  }

  @MainActor
  func application(_ application: NSApplication, open urls: [URL]) {
    DebugLog.write("Received \(urls.map(\.absoluteString))")
    guard let url = urls.last else { return }
    AppController.shared.showWindow()
    MeetController.shared.open(url)
  }

  /// Clicking the Dock icon brings back a hidden main window.
  @MainActor
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    AppController.shared.showWindow()
    return false
  }

  @MainActor
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let app = AppController.shared
    if app.isQuittingFromWindowClose && !app.asksBeforeLeavingOnClose { return .terminateNow }
    let confirmed = AppController.confirmLeavingMeeting(
      because: "Quitting MacMeet will disconnect you from the current call.",
      confirmTitle: "Quit"
    )
    return confirmed ? .terminateNow : .terminateCancel
  }
}
