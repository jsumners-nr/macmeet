import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettings()
        .tabItem { Label("General", systemImage: "gearshape") }
      MeetingSettings()
        .tabItem { Label("Meetings", systemImage: "video") }
      ShortcutSettings()
        .tabItem { Label("Shortcuts", systemImage: "keyboard") }
      TroubleshootingSettings()
        .tabItem { Label("Troubleshooting", systemImage: "ladybug") }
    }
  }
}

/// Lays out one settings tab as a grouped form sized to its content, so the window fits each tab.
private struct SettingsTab<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .frame(width: 460)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// What happens to the window and the app when the window is closed.
private struct GeneralSettings: View {
  @ObservedObject private var app = AppController.shared

  private var keepsRunning: Bool { app.closeBehavior == .keepRunning }

  private var menuBarBinding: Binding<Bool> {
    Binding(
      get: { app.effectiveKeepInMenuBar },
      set: { app.keepInMenuBar = $0 }
    )
  }

  var body: some View {
    SettingsTab {
      Section {
        Picker("When the main window is closed", selection: $app.closeBehavior) {
          Text("Quit MacMeet").tag(AppController.CloseBehavior.quit)
          Text("Keep MacMeet running").tag(AppController.CloseBehavior.keepRunning)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()

        Toggle("Ask before leaving a meeting", isOn: $app.asksBeforeLeavingOnClose)
      } header: {
        Text("When the main window is closed")
      }

      Section {
        Toggle("Keep icon in the Dock", isOn: $app.keepInDock)
          .disabled(!keepsRunning)

        Toggle("Keep item in the menu bar", isOn: menuBarBinding)
          .disabled(!keepsRunning || !app.keepInDock)
      } header: {
        Text("While running in the background")
      } footer: {
        if keepsRunning && !app.keepInDock {
          Text("The menu bar item stays while the Dock icon is hidden, so you can always get back to MacMeet.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// How MacMeet sets up a call: the mic and camera on joining, and the screen share picker.
private struct MeetingSettings: View {
  @ObservedObject private var app = AppController.shared

  var body: some View {
    SettingsTab {
      Section {
        Toggle("Mute microphone", isOn: $app.muteMicrophoneOnJoin)
        Toggle("Turn off camera", isOn: $app.turnOffCameraOnJoin)
      } header: {
        Text("When joining a meeting")
      } footer: {
        Text("Applied as soon as Meet's pre-join screen appears, before you click Join.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Picker("Screen share picker", selection: $app.screenSharePickerStyle) {
          Text("Previews").tag(AppController.ScreenSharePickerStyle.previews)
          Text("List").tag(AppController.ScreenSharePickerStyle.list)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
      } header: {
        Text("Screen share picker")
      } footer: {
        Text(app.screenSharePickerStyle == .previews
          ? "Shows a thumbnail of each screen and window, and outlines the one you select."
          : "Lists screens and windows by name.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct ShortcutSettings: View {
  @ObservedObject private var app = AppController.shared

  var body: some View {
    SettingsTab {
      Section {
        Toggle("Use system-wide hotkeys for mute and camera", isOn: $app.useSystemWideHotkeys)
        KeyboardShortcuts.Recorder("Mute/unmute microphone:", name: .toggleMicrophone)
          .disabled(!app.useSystemWideHotkeys)
        KeyboardShortcuts.Recorder("Turn camera on/off:", name: .toggleCamera)
          .disabled(!app.useSystemWideHotkeys)
      } header: {
        Text("Keyboard Shortcuts")
      } footer: {
        Text("When enabled, these shortcuts mute your microphone or turn off your camera during a call, even when MacMeet isn't the active app. Click a shortcut to record a new one.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct TroubleshootingSettings: View {
  @ObservedObject private var app = AppController.shared

  var body: some View {
    SettingsTab {
      Section {
        Toggle("Record debug log", isOn: $app.debugLogging)
        Button("Show Log in Finder") { app.showDebugLog() }
      } header: {
        Text("Troubleshooting")
      } footer: {
        Text("Records the links MacMeet receives and the pages it opens to ~/Library/Logs/MacMeet/MacMeet.log.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
