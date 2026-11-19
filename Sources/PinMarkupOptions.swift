import SwiftUI

struct PinMarkupOptions: View {
    @ObservedObject var controls: PinZoomControls
    let tool: PinDrawingTool
    @Binding var ink: Color
    @Binding var width: CGFloat
    @Binding var dashed: Bool
    @Binding var fontSize: CGFloat

    private var selected: PinStroke? { controls.selection }
    private var kind: PinDrawingTool { selected?.tool ?? tool }
    private var color: Binding<Color> {
        Binding(get: { selected.map { Color(nsColor: $0.color.color) } ?? ink }, set: { value in
            if selected != nil, let color = PinColor(NSColor(value)) { controls.surface?.editStyle(.color(color)) }
            else { ink = value }
        })
    }
    private var points: CGFloat {
        guard let label = selected?.label, let surface = controls.surface else { return fontSize }
        let size = surface.imageRect.size
        return label.fontSize * max(size.width, size.height) / surface.zoom
    }

    var body: some View {
        HStack(spacing: 9) {
            if kind == .hand {
                Text(bilingual("点选图片上的标注来编辑", "Select an annotation to edit it"))
                    .foregroundStyle(.secondary)
            } else {
                if selected != nil { Text(kind.title).fontWeight(.medium); Divider().frame(height: 15) }
                ForEach([Ink.rose, .blue, .sage, .gold], id: \.self) { preset in
                    let ns: NSColor = switch preset {
                    case .rose: .systemRed
                    case .blue: .systemBlue
                    case .sage: .systemGreen
                    default: .systemYellow
                    }
                    Button { color.wrappedValue = Color(nsColor: ns) } label: {
                        Circle().fill(Color(nsColor: ns)).frame(width: 17, height: 17)
                            .overlay { if PinColor(NSColor(color.wrappedValue)) == PinColor(ns) {
                                Circle().strokeBorder(.white, lineWidth: 1.5).padding(2.5)
                            } }.frame(width: 23, height: 26)
                    }.buttonStyle(ReaderButtonStyle()).help(preset.title).accessibilityLabel(preset.title)
                }
                ColorPicker(L("颜色"), selection: color, supportsOpacity: false).labelsHidden().fixedSize().help(L("颜色"))
                if kind == .text || selected?.label != nil {
                    HStack(spacing: 3) {
                        PinFontSizeField(points: points) { value in
                            if selected != nil { controls.surface?.editStyle(.font(value)) }
                            else { fontSize = value }
                        }.frame(width: 60, height: 24)
                        Text("pt").foregroundStyle(.secondary)
                    }.help(bilingual("输入或选择字号", "Enter or select a font size"))
                }
                if let selected, kind.acceptsText, !controls.editingText {
                    Button(selected.label == nil ? bilingual("添加文字", "Add text") : bilingual("编辑文字", "Edit text")) {
                        controls.surface?.editSelectedText()
                    }.hoverHighlight()
                }
                if kind != .text {
                    Menu {
                        ForEach([0.002, 0.004, 0.009], id: \.self) { value in
                            let title = value == 0.002 ? bilingual("细", "Thin") : value == 0.004 ? bilingual("中", "Medium") : bilingual("粗", "Thick")
                            Button { if selected != nil { controls.surface?.editStyle(.width(value)) } else { width = value } }
                                label: { if (selected?.width ?? width) == value { Label(title, systemImage: "checkmark") } else { Text(title) } }
                        }
                        if kind != .pen {
                            Divider()
                            Toggle(bilingual("虚线", "Dashed"), isOn: Binding(get: { selected?.dashed ?? dashed }, set: { value in
                                if selected != nil { controls.surface?.editStyle(.dashed(value)) } else { dashed = value }
                            }))
                        }
                    } label: { Label(bilingual("线型", "Stroke"), systemImage: "line.3.horizontal.decrease") }.fixedSize()
                }
            }
            Spacer(minLength: 4)
            if selected != nil {
                Button { controls.surface?.deleteSelected() } label: { Label(L("删除"), systemImage: "trash") }
                    .help(bilingual("删除选中的标注（Delete）", "Delete selected annotation (Delete)")).hoverHighlight()
                    .accessibilityIdentifier("pin.markup.delete")
            }
        }.font(.system(size: 13)).controlSize(.regular).padding(.horizontal, 9).frame(height: 35)
            .background { OptionsArea(controls: controls).allowsHitTesting(false).accessibilityHidden(true) }
            .background(PaperStyle.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct OptionsArea: NSViewRepresentable {
    let controls: PinZoomControls
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { controls.optionsArea = view }
}

private struct PinFontSizeField: NSViewRepresentable {
    let points: CGFloat
    let change: (CGFloat) -> Void

    final class Coordinator: NSObject, NSComboBoxDelegate {
        let format: NumberFormatter = {
            let format = NumberFormatter()
            format.numberStyle = .decimal
            format.usesGroupingSeparator = false
            format.maximumFractionDigits = 2
            return format
        }()
        var points: CGFloat = 16
        var change: ((CGFloat) -> Void)?
        func display(_ value: CGFloat) -> String { format.string(from: NSNumber(value: Double(value))) ?? String(Double(value)) }

        @objc func commit(_ field: NSComboBox) {
            let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let decimal = raw.replacingOccurrences(of: format.decimalSeparator ?? ".", with: ".")
            if raw != display(points), let number = Double(decimal), number.isFinite, (1...512).contains(number), CGFloat(number) != points {
                points = CGFloat(number)
                change?(points)
            }
            field.stringValue = display(points)
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox, let choice = field.objectValueOfSelectedItem as? String else { return }
            field.stringValue = choice
            commit(field)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSComboBox { commit(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox {
        let field = NSComboBox()
        field.identifier = NSUserInterfaceItemIdentifier("pin.markup.fontSize")
        field.addItems(withObjectValues: [8, 10, 12, 14, 16, 18, 20, 24, 26, 28, 32, 36, 40, 48, 72].map(String.init))
        field.numberOfVisibleItems = 9
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSComboBox, context: Context) {
        let coordinator = context.coordinator
        coordinator.change = change
        coordinator.points = points
        if field.currentEditor() == nil { field.stringValue = coordinator.display(points) }
        field.setAccessibilityLabel(bilingual("字号", "Font size"))
    }
}
