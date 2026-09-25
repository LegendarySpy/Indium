import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            LabeledContent("Font") {
                HStack(spacing: 8) {
                    ForEach(FontChoice.allCases) { choice in
                        FontSwatch(choice: choice, selected: settings.font == choice) { settings.font = choice }
                    }
                }
            }

            LabeledContent("Text Size") {
                HStack {
                    Slider(value: $settings.textSize, in: AppSettings.textSizes, step: 1)
                    Text("\(Int(settings.textSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Picker("Line Width", selection: $settings.lineWidth) {
                ForEach(LineWidth.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Show Markdown", selection: $settings.syntax) {
                ForEach(SyntaxVisibility.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Check spelling while typing", isOn: $settings.spellcheck)

            Section {
                Toggle("Show page lines", isOn: $settings.showPageLines)
            } footer: {
                Text("Dashed lines show where each page of an exported PDF starts. Type /page break to start a new page yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Suggest note icons", isOn: $settings.suggestIcons)
                    .disabled(!NoteIcons.isAvailable)
            } footer: {
                Text(NoteIcons.unavailableReason ?? "Apple Intelligence picks a symbol for each note, on this Mac. Icons are kept by Indium, not written into your notes. Add icon: to a note's frontmatter to choose your own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FontSwatch: View {
    let choice: FontChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text("Aa")
                    .font(Font(Typography.baseFont(choice, size: 20, weight: .regular)))
                    .frame(width: 58, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.primary.opacity(selected ? 0.1 : 0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 0.5)
                    )
                Text(choice.title)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
