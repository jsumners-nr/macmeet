import SwiftUI

struct ScreenSharePicker: View {
  let request: ScreenShareController.PickerRequest
  let onShare: (ScreenShareController.Source) -> Void
  let onCancel: () -> Void

  @ObservedObject private var screenShare = ScreenShareController.shared
  @State private var category: Category = .screen
  @State private var selection: String?

  private enum Category: String, CaseIterable, Identifiable {
    case screen = "Entire Screen"
    case window = "Window"
    var id: Self { self }
  }

  private var sources: [ScreenShareController.Source] {
    category == .screen ? request.displays : request.windows
  }

  private var systemImage: String {
    category == .screen ? "display" : "macwindow"
  }

  private var selected: ScreenShareController.Source? {
    (request.displays + request.windows).first { $0.id == selection }
  }

  private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16, alignment: .top)]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Share Your Screen")
        .font(.headline)

      if !request.windows.isEmpty {
        Picker("", selection: $category) {
          ForEach(Category.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 280)
        .onChange(of: category) { _, newValue in selectFirstIfNeeded(in: newValue) }
      }

      ScrollView {
        LazyVGrid(columns: columns, spacing: 16) {
          ForEach(sources) { source in
            tile(for: source)
          }
        }
        .padding(.vertical, 4)
      }
      .frame(width: 560, height: 340)

      // ScreenCaptureKit only reports windows on other Spaces as off screen, alongside minimized
      // and hidden ones, and apps stop drawing windows that aren't visible.
      Label(
        "Only windows on this desktop are listed. To share a window from another desktop, move it to this desktop first.",
        systemImage: "info.circle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(width: 560, alignment: .leading)
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
    .onAppear {
      selection = request.displays.first?.id
      updateHighlight()
    }
    .onDisappear { SelectionHighlightOverlay.shared.hide() }
    .onChange(of: selection) { _, _ in updateHighlight() }
  }

  /// Outlines the display or window that's currently selected, so it's clear what will be shared.
  private func updateHighlight() {
    guard let selected else {
      SelectionHighlightOverlay.shared.hide()
      return
    }
    switch selected.content {
    case .display(let display):
      SelectionHighlightOverlay.shared.show(on: display.displayID)
    case .window(let window):
      SelectionHighlightOverlay.shared.show(window: window.frame)
    }
  }

  /// Keeps the Share button meaningful when it switches tabs: if nothing selected is in the
  /// newly shown category, selects that category's first item instead of leaving a hidden pick.
  private func selectFirstIfNeeded(in category: Category) {
    let visible = category == .screen ? request.displays : request.windows
    guard !visible.contains(where: { $0.id == selection }) else { return }
    selection = visible.first?.id
  }

  private func tile(for source: ScreenShareController.Source) -> some View {
    let isSelected = selection == source.id
    return Button {
      selection = source.id
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        preview(for: source, isSelected: isSelected)

        HStack(spacing: 6) {
          if let icon = source.icon {
            Image(nsImage: icon)
              .resizable()
              .frame(width: 16, height: 16)
          } else {
            Image(systemName: systemImage)
              .frame(width: 16, height: 16)
          }
          VStack(alignment: .leading, spacing: 0) {
            Text(source.title)
              .font(.caption)
              .lineLimit(1)
            Text(source.subtitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }
    }
    .buttonStyle(.plain)
  }

  private func preview(for source: ScreenShareController.Source, isSelected: Bool) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.gray.opacity(0.15))
      if let thumbnail = screenShare.thumbnails[source.id] {
        Image(nsImage: thumbnail)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .padding(2)
      } else {
        Image(systemName: systemImage)
          .font(.title)
          .foregroundStyle(.secondary)
      }
    }
    .frame(height: 100)
    .frame(maxWidth: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
    )
  }
}
