import DisplayMenuKit
import SwiftUI

struct PanelView: View {
  let model: PanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Displays").font(.headline)
      ForEach(model.rows) { row in
        RowView(model: model, row: row)
      }
      if let note = model.panelNote { NoteText(note) }
      if let note = model.safetyNetNote { NoteText(note) }
      Divider()
      Button("Quit") { exit(0) }
    }
    .padding()
    .frame(width: 300)
    .onAppear { Task { await model.panelOpened() } }
    .onDisappear { model.panelClosed() }
  }
}

private struct RowView: View {
  let model: PanelModel
  let row: DisplayRow

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(row.name).lineLimit(1)
        Spacer()
        if row.isBusy { ProgressView().controlSize(.small) }
        Toggle(row.name, isOn: isOn)
          .toggleStyle(.switch)
          .labelsHidden()
          .disabled(!row.isSwitchEnabled)
      }
      if let caption = row.caption { NoteText(caption) }
      if let error = row.error { NoteText(error) }
      if row.showsBrightness { BrightnessView(model: model, id: row.id) }
    }
  }

  /// Shows the real state; a flip starts the operation and the next refresh moves the switch.
  private var isOn: Binding<Bool> {
    Binding(
      get: { row.isOn },
      set: { on in
        let id = row.id
        Task { await model.setDisplay(id, on: on) }
      })
  }
}

private struct BrightnessView: View {
  let model: PanelModel
  let id: UUID

  var body: some View {
    let state = model.brightness(for: id)
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Image(systemName: "sun.max").foregroundStyle(.secondary)
        // The model receives every value synchronously, in the order the slider produces them.
        Slider(
          value: Binding(
            get: { Double(model.brightness(for: id)?.sliderValue ?? 50) },
            set: { model.setBrightness(Int($0.rounded()), for: id) }),
          in: 0...100, step: 1)
        Text(state?.percent.map { "\($0)%" } ?? "—")
          .monospacedDigit()
          .frame(width: 40, alignment: .trailing)
      }
      if let error = state?.error { NoteText(error) }
    }
  }
}

private struct NoteText: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
  }
}
