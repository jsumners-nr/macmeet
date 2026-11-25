import SwiftUI

/// The original screen share picker: a plain list of displays and windows by name, without
/// `ScreenSharePicker`'s thumbnails or on-screen highlight.
struct ScreenShareListPicker: View {
  let request: ScreenShareController.PickerRequest
  let onShare: (ScreenShareController.Source) -> Void
  let onCancel: () -> Void

  @State private var selection: String?

  private var selected: ScreenShareController.Source? {
    (request.displays + request.windows).first { $0.id == selection }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Share Your Screen")
        .font(.headline)

      List(selection: $selection) {
        Section("Entire Screen") {
          ForEach(request.displays) { row(for: $0, systemImage: "display") }
        }
        if !request.windows.isEmpty {
          Section("Window") {
            ForEach(request.windows) { row(for: $0, systemImage: "macwindow") }
          }
        }
      }
      .frame(width: 440, height: 340)

      // ScreenCaptureKit only reports windows on other Spaces as off screen, alongside minimized
      // and hidden ones, and apps stop drawing windows that aren't visible.
      Label(
        "Only windows on this desktop are listed. To share a window from another desktop, move it to this desktop first.",
        systemImage: "info.circle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(width: 440, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Share") {
          if let selected { onShare(selected) }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(selected == nil)
      }
    }
    .padding(20)
    .onAppear { selection = request.displays.first?.id }
  }

  private func row(for source: ScreenShareController.Source, systemImage: String) -> some View {
    Label {
      VStack(alignment: .leading) {
        Text(source.title)
        Text(source.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } icon: {
      if let icon = source.icon {
        Image(nsImage: icon)
          .resizable()
          .frame(width: 24, height: 24)
      } else {
        Image(systemName: systemImage)
          .font(.title3)
          .frame(width: 24, height: 24)
      }
    }
    .tag(source.id)
  }
}
