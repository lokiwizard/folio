import SwiftUI

extension Reader {
    func setPinColor(_ color: PinColor?, for ref: CardReference) {
        guard ref.document == key, ref.list == .pins,
              let i = state.pins.firstIndex(where: { $0.id == ref.id }), state.pins[i].color != color else { return }
        state.pins[i].color = color
    }
}

struct PinColorEditor: View {
    @ObservedObject var r: Reader
    let reference: CardReference
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let selected = r.state.pins.first { $0.id == reference.id }?.color
        VStack(alignment: .leading, spacing: 16) {
            Text(L("卡片颜色")).font(.headline)
            HStack(spacing: 12) {
                ForEach(Ink.allCases) { ink in
                    let preset = PinColor(ink.color)
                    Button { r.setPinColor(preset, for: reference) } label: {
                        Circle().fill(Color(nsColor: ink.color)).frame(width: 25, height: 25)
                            .overlay {
                                if selected == preset {
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                                }
                            }
                    }.buttonStyle(.plain).help(ink.title).accessibilityLabel(ink.title)
                        .accessibilityAddTraits(selected == preset ? .isSelected : [])
                }
            }
            ColorPicker(L("自选颜色"), selection: Binding(
                get: { Color(nsColor: selected?.color ?? .controlAccentColor) },
                set: { if let value = PinColor(NSColor($0)) { r.setPinColor(value, for: reference) } }
            ), supportsOpacity: false)
            Divider()
            HStack {
                Button(L("恢复默认颜色")) { r.setPinColor(nil, for: reference) }.disabled(selected == nil)
                Spacer()
                Button(L("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 265)
    }
}
