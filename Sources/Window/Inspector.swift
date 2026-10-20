import AppKit

/// The panel on the window's right edge, the file sidebar's mirror, for the technical
/// side of a note: its variables now, and the table or graph the caret is in. It keeps
/// nothing of its own: it reads the note, and every change it makes is an edit of the
/// note that undoes in one step, so edits from elsewhere (another app, an agent, Undo)
/// just show up in it.
final class InspectorView: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 272

    weak var editor: EditorController? {
        didSet { refresh() }
    }
    /// Escape: back to the page.
    var onDismiss: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Note")
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let variables = VariablesSection()
    private let chart = ChartSection()
    /// Where the chart shown starts, while one is: its controls change that chart and no
    /// other, whatever the caret has done since.
    private var shownChart: Int?
    private var refreshQueued = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Inspector")

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 16, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(chart)
        stack.addArrangedSubview(variables)
        chart.isHidden = true
        chart.onEdit = { [weak self] name, edit in
            guard let self, let editor = self.editor, let location = self.shownChart, editor.chartBlock(containing: location) != nil else { return }
            editor.changeChart(at: location, actionName: name, edit)
        }
        chart.onEditSource = { [weak self] in
            guard let self, let editor = self.editor, let location = self.shownChart, editor.chartBlock(containing: location) != nil else { return }
            editor.showChartSource(at: location)
        }
        variables.onChange = { [weak self] name, edit in self?.editor?.changeVariables(actionName: name, edit) ?? false }
        variables.onDismiss = { [weak self] in self?.onDismiss?() }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            variables.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            chart.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// True while one of its fields has the keys.
    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    func focus() {
        if !chart.isHidden { chart.focusFirst() } else { variables.focusFirst() }
    }

    /// The chart section's first field, once the panel has read the note.
    func focusChart() {
        reload()
        if !chart.isHidden { chart.focusFirst() }
    }

    /// Reads the note again, on the next turn of the run loop so a burst of edits and
    /// caret moves reads it once.
    func refresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshQueued = false
                self.reload()
            }
        }
    }

    private func reload() {
        guard let editor, editor.note != nil else {
            titleLabel.stringValue = "Inspector"
            variables.show(entries: [], text: "", editable: false)
            return
        }
        chart.isHidden = true
        shownChart = nil
        switch editor.inspectorContext {
        case .note: titleLabel.stringValue = "Note"
        case .table: titleLabel.stringValue = "Table"
        case let .chart(location):
            if let info = editor.styler.chart(at: location, in: editor.storage) {
                let graph = info.language.lowercased() == "desmos-graph"
                titleLabel.stringValue = graph ? "Graph" : "Chart"
                chart.show(graph: graph, body: info.body, model: info.model, columns: info.columns, editable: editor.textView.isEditable)
                chart.isHidden = false
                shownChart = location
            }
        }
        let text = editor.text
        variables.show(entries: VariableEditing.entries(noteText: text), text: text, editable: editor.textView.isEditable)
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    #if DEBUG
    func debugDump() -> String {
        "title: \(titleLabel.stringValue)\n" + (chart.isHidden ? "" : chart.debugDump() + "\n") + variables.debugDump()
    }

    /// `set:name=value`, `rename:old=new`, `add:name=value`, `delete:name`: typed into the
    /// fields and committed as leaving them would.
    func debugStep(_ step: String) {
        reload()
        if step.hasPrefix("chart.") { chart.debugStep(String(step.dropFirst(6))) } else { variables.debugStep(step) }
    }
    #endif
}

// MARK: - Variables

/// The note's frontmatter numbers: name, value (with its unit), and how many formulas
/// read each. Names and values are edited in place; a new one is typed whole, as
/// `mass = 2 g`, in the field below them.
private final class VariablesSection: NSView, NSTextFieldDelegate {
    /// Makes a change (named for Undo) to the note's text; false when it was refused.
    var onChange: ((String, (String) -> String?) -> Bool)?
    var onDismiss: (() -> Void)?

    private let header = SectionHeader(title: "Variables")
    private let rows = NSStackView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let others = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var shown: [VariableEditing.Entry] = []
    private var text = ""
    /// Where a new variable is typed, name and value together.
    private let addField = InspectorField()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        header.addButton.target = self
        header.addButton.action = #selector(addClicked)
        header.addButton.toolTip = "Add Variable"
        header.addButton.setAccessibilityLabel("Add Variable")

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4

        empty.stringValue = "Name a number once, then use it in this note’s formulas and answers."
        for label in [empty, others, message] {
            label.font = NSFont.systemFont(ofSize: 11)
            // System label colors: they stay readable on the glass in light and dark.
            label.textColor = .secondaryLabelColor
            label.isSelectable = false
        }
        message.isHidden = true
        addField.placeholderString = "Add a variable, like mass = 2 g"
        addField.setAccessibilityLabel("New Variable")
        addField.delegate = self

        let column = NSStackView(views: [header, rows, addField, message, empty, others])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.setCustomSpacing(8, after: header)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for v in [header, rows, addField, empty, others, message] as [NSView] {
            v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the variables in `entries`. While a row holds typing that isn't in the note
    /// yet, the rows are left alone, so a change made elsewhere never takes it away;
    /// otherwise they're rebuilt and the field that had the keys keeps them.
    func show(entries: [VariableEditing.Entry], text: String, editable: Bool) {
        self.text = text
        header.addButton.isEnabled = editable
        addField.isEditable = editable
        addField.isHidden = !editable
        let current = rows.arrangedSubviews.compactMap { $0 as? VariableRow }
        if current.contains(where: { $0.hasUncommittedTyping }) { return }
        let variables = entries.filter { $0.quantity != nil }
        let changed = variables.map { [$0.name, $0.value] } != shown.map { [$0.name, $0.value] }
        shown = variables
        if changed {
            let focused = current.first { $0.focusedField != nil }.map { ($0.originalName, $0.focusedField!) }
            current.forEach { $0.removeFromSuperview() }
            for (i, entry) in variables.enumerated() {
                let row = VariableRow(name: entry.name, value: entry.value, delegate: self)
                rows.insertArrangedSubview(row, at: i)
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                if let (name, field) = focused, name == entry.name { field == .name ? row.focusName() : row.focusValue() }
            }
        }
        for case let row as VariableRow in rows.arrangedSubviews {
            row.isEditable = editable
            let uses = VariableEditing.uses(of: row.originalName, in: text)
            row.uses = uses == 0 ? "" : uses == 1 ? "1 formula" : "\(uses) formulas"
        }
        empty.isHidden = !variables.isEmpty
        let skipped = entries.compactMap { entry -> String? in
            switch entry.status {
            case .variable: return nil
            case .overridden: return "\(entry.name): set again below"
            case let .skipped(why): return "\(entry.name): \(why.lowercased())"
            }
        }
        others.stringValue = skipped.isEmpty ? "" : "Not used as variables: " + skipped.joined(separator: "; ")
        others.isHidden = skipped.isEmpty
    }

    func focusFirst() {
        if let row = rows.arrangedSubviews.first as? VariableRow { row.focusValue() } else { addClicked() }
    }

    @objc private func addClicked() {
        window?.makeFirstResponder(addField)
    }

    /// A quiet hint under the fields about what to type; nil clears it.
    private func say(_ problem: String?) {
        message.stringValue = problem ?? ""
        message.isHidden = problem == nil
    }

    // MARK: Adding

    /// `mass = 2 g`, `mass: 2 g` or `mass 2 g` as a name and a value. Spaces in the name
    /// become _, so "molar mass = 18 g/mol" is molar_mass.
    static func parseNew(_ typed: String) -> (name: String, value: String)? {
        let t = typed.trimmingCharacters(in: .whitespaces)
        let name: String, value: String
        if let sep = t.firstIndex(where: { $0 == "=" || $0 == ":" }) {
            name = String(t[..<sep])
            value = String(t[t.index(after: sep)...])
        } else {
            // No = or :, so the value starts at the first word that's a number.
            let words = t.split(whereSeparator: \.isWhitespace)
            guard let i = words.indices.dropFirst().first(where: { words[$0].first.map { $0.isNumber || $0 == "-" || $0 == "." } ?? false })
            else { return nil }
            name = words[..<i].joined(separator: " ")
            value = words[i...].joined(separator: " ")
        }
        let cleanName = name.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace).joined(separator: "_")
        let cleanValue = value.trimmingCharacters(in: .whitespaces)
        guard !cleanName.isEmpty, !cleanValue.isEmpty else { return nil }
        return (cleanName, cleanValue)
    }

    /// Puts what's typed in the add field into the note, or says what to change.
    private func addTyped() {
        let typed = addField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { say(nil); return }
        guard let (name, value) = Self.parseNew(typed) else {
            say("Type a name and a number, like mass = 2 g.")
            return
        }
        if let problem = problem(name: name, value: value, replacing: nil) {
            say(problem)
            return
        }
        say(nil)
        if onChange?("Add Variable", { VariableEditing.setting(name, to: value, in: $0) }) == true {
            addField.stringValue = ""
            shown = []
        } else {
            say("Couldn’t add “\(name)” to this note.")
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === addField else { return }
        // Return adds it; clicking away keeps the typing for later, unless it's ready.
        let movement = obj.userInfo?["NSTextMovement"] as? Int
        if movement == NSTextMovement.return.rawValue {
            addTyped()
            if !addField.stringValue.isEmpty { window?.makeFirstResponder(addField) }
        } else if let (name, value) = Self.parseNew(addField.stringValue), problem(name: name, value: value, replacing: nil) == nil {
            addTyped()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === addField, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        addField.stringValue = ""
        say(nil)
        onDismiss?()
        return true
    }

    // MARK: Committing

    /// A field of `row` was left: put its change in the note, or say why it can't go in.
    fileprivate func commit(_ row: VariableRow, field: VariableRow.Field) {
        let name = row.name.trimmingCharacters(in: .whitespaces)
        let value = row.value.trimmingCharacters(in: .whitespaces)
        switch field {
        case .name:
            let name = name.split(whereSeparator: \.isWhitespace).joined(separator: "_")
            guard name != row.originalName else { say(nil); row.name = name; return }
            if let problem = problem(name: name, value: nil, replacing: row.originalName) {
                say(problem)
                row.name = row.originalName
                return
            }
            say(nil)
            let old = row.originalName
            // The row may still be in use (Tab to its value) before the inspector reads the note again.
            if onChange?("Rename Variable", { VariableEditing.renaming(old, to: name, in: $0) }) == true { row.accept() } else { row.revert() }
        case .value:
            guard value != row.originalValue else { say(nil); return }
            if value.isEmpty {
                say(nil)
                let old = row.originalName
                _ = onChange?("Delete Variable") { VariableEditing.removing(old, in: $0) }
                return
            }
            if let problem = problem(name: nil, value: value, replacing: row.originalName) {
                say(problem)
                row.value = row.originalValue
                return
            }
            say(nil)
            let old = row.originalName
            if onChange?("Change Variable", { VariableEditing.setting(old, to: value, in: $0) }) == true { row.accept() } else { row.revert() }
        }
    }

    /// What's wrong with a name or value, in a few words, or nil.
    private func problem(name: String?, value: String?, replacing: String?) -> String? {
        if let name {
            if Evaluator.isReserved(name) { return "“\(name)” already means something in formulas. Try another name." }
            if name.first?.isNumber == true { return "Names can’t start with a number." }
            if !VariableEditing.isValidName(name) { return "Use only letters and numbers in the name." }
            if name != replacing, shown.contains(where: { $0.name == name }) { return "“\(name)” is already a variable." }
        }
        if let value, Quantity.parse(value) == nil || value.hasPrefix("*") || value.hasPrefix("_") {
            return "Use a number for the value, like 2, 2.5 g or 85%."
        }
        return nil
    }

    fileprivate func delete(_ row: VariableRow) {
        say(nil)
        let old = row.originalName
        _ = onChange?("Delete Variable") { VariableEditing.removing(old, in: $0) }
    }

    fileprivate func cancel(_ row: VariableRow) {
        say(nil)
        row.revert()
        onDismiss?()
    }

    #if DEBUG
    func debugStep(_ step: String) {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let kv = parts[1].split(separator: "=", maxSplits: 1).map(String.init)
        let row = { (name: String) in self.rows.arrangedSubviews.compactMap { $0 as? VariableRow }.first { $0.originalName == name } }
        switch parts[0] {
        case "set": if let r = row(kv[0]), kv.count == 2 { r.value = kv[1]; commit(r, field: .value) }
        case "rename": if let r = row(kv[0]), kv.count == 2 { r.name = kv[1]; commit(r, field: .name) }
        case "delete": if let r = row(kv[0]) { delete(r) }
        case "add":
            // `add:mass = 2 g`, as typed in the add field.
            addField.stringValue = parts[1]
            addTyped()
        default: print("  unknown step", step)
        }
    }

    func debugDump() -> String {
        rows.arrangedSubviews.compactMap { $0 as? VariableRow }.map { "\($0.name) = \($0.value) [\($0.uses)]" }.joined(separator: "\n")
            + (others.isHidden ? "" : "\n" + others.stringValue) + (message.isHidden ? "" : "\nmessage: " + message.stringValue)
    }
    #endif
}

/// A section's title and its + button.
private final class SectionHeader: NSView {
    let addButton: HoverButton
    private let label = NSTextField(labelWithString: "")

    func setTitle(_ title: String) { label.stringValue = title.uppercased() }

    init(title: String) {
        addButton = HoverButton(symbol: "plus", label: "Add", pointSize: 11, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title.uppercased()
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityRole(.staticText)
        for v in [label, addButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// One variable: its name and value as editable text, how many formulas read it, and
/// a delete button that shows on hover.
private final class VariableRow: NSView, NSTextFieldDelegate {
    enum Field { case name, value }

    private let nameField = InspectorField()
    private let valueField = InspectorField()
    private let usesLabel = NSTextField(labelWithString: "")
    private let deleteButton = HoverButton(symbol: "minus.circle", label: "Delete Variable", pointSize: 11, target: nil, action: nil)
    private weak var section: VariablesSection?
    private(set) var originalName: String
    private(set) var originalValue: String
    private var hovering = false { didSet { updateChrome() } }

    var name: String {
        get { nameField.stringValue }
        set { nameField.stringValue = newValue }
    }
    var value: String {
        get { valueField.stringValue }
        set { valueField.stringValue = newValue }
    }
    var uses: String {
        get { usesLabel.stringValue }
        set { usesLabel.stringValue = newValue; usesLabel.isHidden = newValue.isEmpty }
    }
    var isEditable = true {
        didSet {
            nameField.isEditable = isEditable
            valueField.isEditable = isEditable
            updateChrome()
        }
    }
    /// The field with the keys, if it's one of this row's.
    var focusedField: Field? {
        guard let editor = window?.firstResponder as? NSText, let field = editor.delegate as? NSTextField else { return nil }
        return field === nameField ? .name : field === valueField ? .value : nil
    }
    /// Typed but not put in the note yet.
    var hasUncommittedTyping: Bool {
        focusedField != nil && (name.trimmingCharacters(in: .whitespaces) != originalName || value.trimmingCharacters(in: .whitespaces) != originalValue)
    }

    init(name: String, value: String, delegate: VariablesSection) {
        originalName = name
        originalValue = value
        section = delegate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        nameField.stringValue = name
        nameField.placeholderString = "Name"
        nameField.setAccessibilityLabel("Variable Name")
        valueField.stringValue = value
        valueField.placeholderString = "Value"
        valueField.setAccessibilityLabel(name.isEmpty ? "Value" : "Value of \(name)")
        for field in [nameField, valueField] { field.delegate = self }
        usesLabel.font = NSFont.systemFont(ofSize: 10)
        usesLabel.toolTip = "Table formulas that use this variable"
        usesLabel.alignment = .right
        usesLabel.textColor = .secondaryLabelColor
        usesLabel.isHidden = true
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.toolTip = "Delete Variable"

        for v in [nameField, valueField, usesLabel, deleteButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        usesLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.widthAnchor.constraint(equalToConstant: 84),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 6),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
            usesLabel.leadingAnchor.constraint(equalTo: valueField.trailingAnchor, constant: 6),
            // A fixed slot, so every row's value field is as wide as the others.
            usesLabel.widthAnchor.constraint(equalToConstant: 58),
            usesLabel.firstBaselineAnchor.constraint(equalTo: valueField.firstBaselineAnchor),
            deleteButton.leadingAnchor.constraint(equalTo: usesLabel.trailingAnchor, constant: 2),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func updateChrome() {
        deleteButton.alphaValue = hovering && isEditable ? 1 : 0
        deleteButton.isEnabled = isEditable
    }

    func focusName() { window?.makeFirstResponder(nameField) }
    func focusValue() { window?.makeFirstResponder(valueField) }

    func revert() {
        name = originalName
        value = originalValue
    }

    /// What the fields hold is in the note now.
    func accept() {
        originalName = name.trimmingCharacters(in: .whitespaces)
        originalValue = value.trimmingCharacters(in: .whitespaces)
    }

    @objc private func deleteClicked() { section?.delete(self) }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        section?.commit(self, field: field === nameField ? .name : .value)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            section?.cancel(self)
            return true
        }
        return false
    }
}

/// The inspector's text field: a standard small rounded field, as in Pages' and
/// Xcode's inspectors, so its text, focus ring and colors are the system's own.
private final class InspectorField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBezeled = true
        bezelStyle = .roundedBezel
        controlSize = .small
        font = InspectorStyle.font
        isEditable = true
        isSelectable = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.usesSingleLineMode = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Type sizes shared by the inspector's controls and labels.
private enum InspectorStyle {
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
    static let label: (String) -> NSTextField = { text in
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = .secondaryLabelColor
        return l
    }
}

// MARK: - Charts and graphs

/// The chart or graph selected in the note, built here instead of in its Markdown: a
/// graph's equations and range, or a chart's type, titles, columns and curves. Every
/// change is written back into the block in the plugin's own format, one undo step each.
private final class ChartSection: NSView, NSTextFieldDelegate {
    /// (undo name, the change to the block's body)
    var onEdit: ((String, @escaping (String) -> String) -> Void)?
    var onEditSource: (() -> Void)?

    private let column = NSStackView()
    // Graph
    private let equationsHeader = SectionHeader(title: "Equations")
    private let equations = EquationList(styled: true, placeholder: "y=x^2")
    private let rangeHeader = SectionHeader(title: "Range")
    private let rangeGrid = NSGridView()
    private let left = InspectorField(), right = InspectorField(), bottom = InspectorField(), top = InspectorField()
    private let gridLines = NSButton(checkboxWithTitle: "Grid lines", target: nil, action: nil)
    // Chart
    private let chartGrid = NSGridView()
    private let type = NSPopUpButton()
    private let style = NSPopUpButton()
    private let titleField = InspectorField()
    private let xTitle = InspectorField()
    private let yTitle = InspectorField()
    private let seriesHeader = SectionHeader(title: "Columns")
    private let series = NSStackView()
    private let optionsHeader = SectionHeader(title: "Options")
    private let bestFit = NSButton(checkboxWithTitle: "Line of best fit", target: nil, action: nil)
    private let zero = NSButton(checkboxWithTitle: "Start y at zero", target: nil, action: nil)
    private let legend = NSButton(checkboxWithTitle: "Legend", target: nil, action: nil)
    private let valuesHeader = SectionHeader(title: "Values")
    private let values = InlineDataList()
    private let pointsHeader = SectionHeader(title: "Points")
    private let pointsName = InspectorField()
    private let points = PointList()
    private let curvesHeader = SectionHeader(title: "Lines and Curves")
    private let curves = EquationList(styled: false, placeholder: "y = 2x + 1, or y = 3")
    private let curvesHint = NSTextField(wrappingLabelWithString: "y = 3 is a flat line at 3, x = 3 an upright one, and y = 2x + 1 rises 2 for every 1 across.")
    // Both
    private let source = NSTextField(wrappingLabelWithString: "")
    private let problems = NSTextField(wrappingLabelWithString: "")
    private let editSource = NSButton(title: "Edit Markdown", target: nil, action: nil)

    private var graph = false
    private var columns: [String] = []
    private var selected: [String] = []
    private var fieldKeys: [ObjectIdentifier: String] = [:]
    private var shownValues: [ObjectIdentifier: String] = [:]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        type.addItems(withTitles: Self.types.map(\.title))
        type.controlSize = .small
        type.font = InspectorStyle.font
        type.target = self
        type.action = #selector(typeChanged)
        type.setAccessibilityLabel("Chart Type")
        style.addItems(withTitles: ChartModel.Style.allCases.map { $0.rawValue.capitalized })
        // Each with a picture of three bars drawn its way.
        let darkMenu = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for (item, kind) in zip(style.itemArray, ChartModel.Style.allCases) { item.image = ChartPattern.preview(kind, dark: darkMenu) }
        style.controlSize = .small
        style.font = InspectorStyle.font
        style.target = self
        style.action = #selector(styleChanged)
        style.setAccessibilityLabel("Chart Style")
        style.toolTip = "Soft is Indium’s own muted colors, Mono shades of the text color for printing; Hatched and Dotted fill bars and slices with lines or dots"
        pointsName.placeholderString = "Name, like Trial 1"
        pointsName.toolTip = "What the points are, for the legend"
        for (field, key, label) in [(titleField, "title", "Title"), (xTitle, "xTitle", "X Axis Title"), (yTitle, "yTitle", "Y Axis Title"),
                                    (pointsName, "pointsTitle", "Name of Points"),
                                    (left, "left", "Smallest x"), (right, "right", "Largest x"), (bottom, "bottom", "Smallest y"), (top, "top", "Largest y")] {
            field.delegate = self
            field.setAccessibilityLabel(label)
            fieldKeys[ObjectIdentifier(field)] = key
        }
        for b in [bestFit, zero, legend, gridLines] {
            b.target = self
            b.action = #selector(checkboxChanged(_:))
            b.controlSize = .small
            b.font = InspectorStyle.font
        }
        bestFit.toolTip = "A straight line through the middle of the first column’s values, or of your points"
        for label in [source, problems, curvesHint] {
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.isSelectable = false
        }
        problems.textColor = .systemRed
        editSource.bezelStyle = .rounded
        editSource.controlSize = .small
        editSource.font = InspectorStyle.font
        editSource.target = self
        editSource.action = #selector(editSourceClicked)
        editSource.toolTip = "Show this chart’s Markdown in the note"

        chartGrid.addRow(with: [InspectorStyle.label("Type"), type])
        chartGrid.addRow(with: [InspectorStyle.label("Style"), style])
        chartGrid.addRow(with: [InspectorStyle.label("Title"), titleField])
        chartGrid.addRow(with: [InspectorStyle.label("X axis"), xTitle])
        chartGrid.addRow(with: [InspectorStyle.label("Y axis"), yTitle])
        rangeGrid.addRow(with: [InspectorStyle.label("X"), left, InspectorStyle.label("to"), right])
        rangeGrid.addRow(with: [InspectorStyle.label("Y"), bottom, InspectorStyle.label("to"), top])
        right.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        top.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        right.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        for grid in [chartGrid, rangeGrid] {
            grid.rowSpacing = 6
            grid.columnSpacing = 8
            grid.rowAlignment = .firstBaseline
            grid.column(at: 0).width = 52
            grid.column(at: 0).xPlacement = .leading
            grid.column(at: 1).xPlacement = .fill
        }
        rangeGrid.column(at: 0).width = 14
        rangeGrid.column(at: 3).xPlacement = .fill

        series.orientation = .vertical
        series.alignment = .leading
        series.spacing = 4
        let options = NSStackView(views: [bestFit, zero, legend])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 4

        equationsHeader.addButton.target = self
        equationsHeader.addButton.action = #selector(addEquation)
        equationsHeader.addButton.toolTip = "Add Equation"
        equationsHeader.addButton.setAccessibilityLabel("Add Equation")
        curvesHeader.addButton.target = self
        curvesHeader.addButton.action = #selector(addCurve)
        curvesHeader.addButton.toolTip = "Add Line or Curve"
        curvesHeader.addButton.setAccessibilityLabel("Add Line or Curve")
        valuesHeader.addButton.target = self
        valuesHeader.addButton.action = #selector(addValues)
        valuesHeader.addButton.toolTip = "Add Values"
        valuesHeader.addButton.setAccessibilityLabel("Add Values")
        pointsHeader.addButton.target = self
        pointsHeader.addButton.action = #selector(addPoint)
        pointsHeader.addButton.toolTip = "Add Points"
        pointsHeader.addButton.setAccessibilityLabel("Add Points")
        for header in [rangeHeader, seriesHeader, optionsHeader] { header.addButton.isHidden = true }

        equations.onCommit = { [weak self] lines, name in
            self?.onEdit?(name) { ChartBlockEditing.settingGraphLines(lines, in: $0) }
        }
        curves.onCommit = { [weak self] lines, name in
            self?.onEdit?(name) { ChartBlockEditing.settingPlots(lines.map(\.expression), in: $0) }
        }
        values.onCommit = { [weak self] labels, series, name in
            self?.onEdit?(name) { ChartBlockEditing.settingInlineData(labels: labels, series: series, in: $0) }
        }
        points.onCommit = { [weak self] entries, name in
            self?.onEdit?(name) { ChartBlockEditing.settingPoints(entries, in: $0) }
        }

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        let views: [NSView] = [equationsHeader, equations, rangeHeader, rangeGrid, gridLines,
                               chartGrid, seriesHeader, series, valuesHeader, values, pointsHeader, pointsName, points, curvesHeader, curves, curvesHint,
                               optionsHeader, options, problems, source, editSource]
        for v in views { column.addArrangedSubview(v) }
        for v in [equations, rangeGrid, chartGrid, values, points, curvesHint] { column.setCustomSpacing(16, after: v) }
        column.setCustomSpacing(6, after: curves)
        column.setCustomSpacing(16, after: gridLines)
        column.setCustomSpacing(16, after: series)
        column.setCustomSpacing(16, after: options)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for v in [equationsHeader, equations, rangeHeader, chartGrid, seriesHeader, optionsHeader, valuesHeader, values, pointsHeader, points, curvesHeader, curves,
                  curvesHint, problems, source] as [NSView] {
            v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        // Its fields end where the equations' fields do, before their menu buttons.
        rangeGrid.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -20).isActive = true
        pointsName.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24).isActive = true
    }

    /// The chart types offered, as the menu shows them and as the block writes them.
    private static let types: [(title: String, key: String)] = [("Line", "line"), ("Bar", "bar"), ("Scatter", "scatter"), ("Pie", "pie"), ("Doughnut", "doughnut")]

    required init?(coder: NSCoder) { fatalError() }

    func show(graph: Bool, body: String, model: ChartModel, columns: [String], editable: Bool) {
        self.graph = graph
        for v in [equationsHeader, equations, rangeHeader, rangeGrid, gridLines] as [NSView] { v.isHidden = !graph }
        for v in [chartGrid, optionsHeader, bestFit.superview!, curvesHeader, curvesHint, pointsHeader, points] as [NSView] { v.isHidden = graph }
        for v in [valuesHeader, values, pointsName] as [NSView] { v.isHidden = true }
        func set(_ field: InspectorField, _ value: String?, placeholder: String) {
            field.isEditable = editable
            field.placeholderString = placeholder
            shownValues[ObjectIdentifier(field)] = value ?? ""
            // Never under someone typing in it.
            if field.currentEditor() == nil { field.stringValue = value ?? "" }
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var unplaced = model.problems
        if graph {
            let s = ChartBlockEditing.graphSettings(body)
            set(left, s["left"], placeholder: "-10")
            set(right, s["right"], placeholder: "10")
            set(bottom, s["bottom"], placeholder: "-7")
            set(top, s["top"], placeholder: "7")
            gridLines.state = s["grid"]?.lowercased() == "false" ? .off : .on
            gridLines.isEnabled = editable
            equations.show(lines: ChartBlockEditing.graphLines(body), rows: model.rows, style: model.style, dark: dark, editable: editable)
            equationsHeader.addButton.isEnabled = editable
            unplaced = model.problems.filter { p in !ChartBlockEditing.graphLines(body).contains { p.hasPrefix($0.expression + ":") } }
            source.stringValue = "Type equations like y = x^2 or y = 2x + 1, or LaTeX as in Desmos. Variables from the note’s properties work by name."
            seriesHeader.isHidden = true
            series.isHidden = true
            curves.isHidden = true
        } else {
            let s = ChartBlockEditing.chartSettings(body)
            var kind = s["type"]?.lowercased() ?? "line"
            if kind == "donut" { kind = "doughnut" }
            let known = Self.types.map(\.key)
            let pie = kind == "pie" || kind == "doughnut"
            type.selectItem(at: known.firstIndex(of: kind) ?? 0)
            type.isEnabled = editable && known.contains(kind)
            // A pie has no axes.
            chartGrid.row(at: 3).isHidden = pie
            chartGrid.row(at: 4).isHidden = pie
            style.selectItem(at: ChartModel.Style.allCases.firstIndex(of: model.style) ?? 0)
            style.isEnabled = editable
            set(titleField, s["title"], placeholder: "Chart title")
            set(xTitle, s["xTitle"], placeholder: model.xTitle ?? "Across, like Time (s)")
            set(yTitle, s["yTitle"], placeholder: model.yTitle ?? "Up, like Distance (m)")
            bestFit.state = s["bestFit"]?.lowercased() == "true" ? .on : .off
            zero.state = s["beginAtZero"]?.lowercased() == "true" ? .on : .off
            legend.state = s["legend"]?.lowercased() == "false" ? .off : .on
            for b in [bestFit, zero, legend] { b.isEnabled = editable }
            showSeries(columns: columns, selected: MiniYAML.parse(body)["select"]?.list, editable: editable)
            let plots = ChartBlockEditing.plots(body)
            curves.show(lines: plots.map { ChartBlockEditing.GraphLine(expression: $0) }, rows: model.rows, style: model.style, dark: dark, editable: editable)
            // An empty field to type the first one in, so there's no + to find first.
            if plots.isEmpty, editable { curves.addRow(focus: false) }
            curves.isHidden = plots.isEmpty && !curves.hasDraft
            curvesHeader.addButton.isEnabled = editable
            let typed = ChartBlockEditing.points(body)
            points.show(typed, editable: editable)
            pointsHeader.addButton.isEnabled = editable
            set(pointsName, s["pointsTitle"], placeholder: "Name, like Trial 1")
            // Values written in the chart (the plugin's labels and series), the way bars
            // and pies start out; points where x and y are both numbers.
            let data = ChartBlockEditing.inlineData(body)
            let inline = !data.labels.isEmpty || !data.series.isEmpty
            let showsValues = s["id"] == nil && (inline || (kind == "bar" || pie) && typed.isEmpty)
            values.show(labels: data.labels, series: data.series, editable: editable)
            valuesHeader.addButton.isEnabled = editable
            for v in [valuesHeader, values] as [NSView] { v.isHidden = !showsValues }
            // Points go with numbers both ways; a bar or pie of values only shows them once there are some.
            let pointsShown = !typed.isEmpty || !pie && !(showsValues && kind == "bar")
            for v in [pointsHeader, points] as [NSView] { v.isHidden = !pointsShown }
            pointsName.isHidden = typed.isEmpty
            for v in [curvesHeader, curvesHint, bestFit, zero] as [NSView] { v.isHidden = pie }
            if pie { curves.isHidden = true }
            unplaced = model.problems.filter { p in !plots.contains { p.hasPrefix($0 + ":") } }
            source.stringValue = s["id"].map { "Values from the table marked ^\($0). Change them in the table." } ?? ""
        }
        source.isHidden = source.stringValue.isEmpty
        problems.stringValue = unplaced.joined(separator: "\n")
        problems.isHidden = unplaced.isEmpty
        editSource.isEnabled = editable
    }

    /// A checkbox for each column of the linked table; checked ones are drawn.
    private func showSeries(columns: [String], selected: [String]?, editable: Bool) {
        let chosen = selected ?? columns
        let changed = columns != self.columns
        self.columns = columns
        self.selected = chosen
        seriesHeader.isHidden = columns.isEmpty
        series.isHidden = columns.isEmpty
        if changed {
            series.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for name in columns {
                let box = NSButton(checkboxWithTitle: name.isEmpty ? "Untitled" : name, target: self, action: #selector(seriesChanged(_:)))
                box.controlSize = .small
                box.font = InspectorStyle.font
                box.identifier = NSUserInterfaceItemIdentifier(name)
                series.addArrangedSubview(box)
            }
        }
        for case let box as NSButton in series.arrangedSubviews {
            box.state = chosen.contains(box.identifier?.rawValue ?? "") ? .on : .off
            box.isEnabled = editable
        }
    }

    @objc private func seriesChanged(_ sender: NSButton) {
        let picked = series.arrangedSubviews.compactMap { $0 as? NSButton }.filter { $0.state == .on }.compactMap { $0.identifier?.rawValue }
        guard !picked.isEmpty else {
            // At least one column stays.
            sender.state = .on
            NSSound.beep()
            return
        }
        let all = columns
        onEdit?("Chart Columns") { ChartBlockEditing.settingSelected(picked, of: all, in: $0) }
    }

    @objc private func addEquation() { equations.addRow() }
    @objc private func addCurve() {
        curves.isHidden = false
        curves.addRow()
    }
    @objc private func addPoint() { points.focusEntry() }
    @objc private func addValues() { values.addSeries() }
    @objc private func editSourceClicked() { onEditSource?() }

    /// Puts the keys in the first equation, or a new one when there are none.
    func focusFirst() {
        if graph { equations.focusFirst() } else { window?.makeFirstResponder(titleField) }
    }

    private func setting(_ name: String, _ key: String, _ value: String?) {
        let graph = self.graph
        onEdit?(name) { graph ? ChartBlockEditing.settingGraph(key, to: value, in: $0) : ChartBlockEditing.settingChart(key, to: value, in: $0) }
    }

    @objc private func typeChanged() {
        setting("Chart Type", "type", Self.types[max(0, type.indexOfSelectedItem)].key)
    }

    /// Soft, the default, is written as no `style:` line at all.
    @objc private func styleChanged() {
        let picked = ChartModel.Style.allCases[max(0, style.indexOfSelectedItem)]
        setting("Chart Style", "style", picked == .soft ? nil : picked.rawValue)
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case bestFit: setting("Line of Best Fit", "bestFit", on ? "true" : nil)
        case zero: setting("Start at Zero", "beginAtZero", on ? "true" : nil)
        case legend: setting("Legend", "legend", on ? nil : "false")
        case gridLines: setting("Grid Lines", "grid", on ? nil : "false")
        default: break
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? InspectorField, let key = fieldKeys[ObjectIdentifier(field)] else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard value != shownValues[ObjectIdentifier(field)] else { return }
        if graph, !value.isEmpty, Double(value) == nil {
            NSSound.beep()
            field.stringValue = shownValues[ObjectIdentifier(field)] ?? ""
            return
        }
        shownValues[ObjectIdentifier(field)] = value
        setting(graph ? "Graph Range" : key == "pointsTitle" ? "Name Points" : "Chart Title", key, value.isEmpty ? nil : value)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? InspectorField {
            field.stringValue = shownValues[ObjectIdentifier(field)] ?? ""
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    #if DEBUG
    func debugDump() -> String {
        graph ? "graph left=\(left.stringValue) right=\(right.stringValue) bottom=\(bottom.stringValue) top=\(top.stringValue) grid=\(gridLines.state == .on)\n" + equations.debugDump()
              : "chart type=\(type.titleOfSelectedItem ?? "") style=\(style.titleOfSelectedItem ?? "") title=\(titleField.stringValue) x=\(xTitle.stringValue)|\(xTitle.placeholderString ?? "") y=\(yTitle.stringValue)|\(yTitle.placeholderString ?? "") fit=\(bestFit.state == .on) columns=\(columns) selected=\(selected)\n" + curves.debugDump()
                + "\npoints \(pointsName.stringValue):\n" + points.debugDump() + (values.isHidden ? "" : "\nvalues:\n" + values.debugDump())
    }

    /// `type:Bar`, `fit`, `field:key=value`, `eq:add=y=2x`, `eq:set=0=y=3x`, `eq:remove=0`,
    /// `eq:color=0=red`, `eq:dash=0=dashed`, `curve:add=y=x`, `column:Volume`,
    /// `point:add=(1, 2), (2, 4)`, `point:x=0=5`, `point:y=0=7`, `point:remove=0`.
    func debugStep(_ step: String) {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let kv = parts.count == 2 ? parts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init) : []
        switch parts[0] {
        case "type": type.selectItem(withTitle: parts[1]); typeChanged()
        case "style": style.selectItem(withTitle: parts[1]); styleChanged()
        case "fit": bestFit.performClick(nil)
        case "field":
            guard kv.count == 2, let field = fieldKeys.first(where: { $0.value == kv[0] }).flatMap({ key in
                [titleField, xTitle, yTitle, pointsName, left, right, bottom, top].first { ObjectIdentifier($0) == key.key } }) else { return }
            field.stringValue = kv[1]
            controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        case "eq": equations.debugStep(kv)
        case "curve": curves.debugStep(kv)
        case "point": points.debugStep(kv)
        case "data": values.debugStep(kv)
        case "column":
            if let box = series.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == parts[1] }) {
                box.performClick(nil)
            }
        default: print("  unknown chart step", step)
        }
    }
    #endif
}

/// Equations as rows, the way Desmos lists them: a color swatch, the equation, and a menu
/// for its line and for taking it out. What's wrong with one shows under it.
private final class EquationList: NSView {
    /// (all the lines, undo name)
    var onCommit: (([ChartBlockEditing.GraphLine], String) -> Void)?

    /// Rows with a color and line style (graphs), or just the curve (a chart's `plot:`).
    let styled: Bool
    let placeholder: String
    private let stack = NSStackView()
    private var lines: [ChartBlockEditing.GraphLine] = []
    private var draft: EquationRow?
    var hasDraft: Bool { draft != nil }

    init(styled: Bool, placeholder: String) {
        self.styled = styled
        self.placeholder = placeholder
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var rows: [EquationRow] { stack.arrangedSubviews.compactMap { $0 as? EquationRow } }

    func show(lines: [ChartBlockEditing.GraphLine], rows info: [ChartModel.Row], style: ChartModel.Style, dark: Bool, editable: Bool) {
        // Typing that isn't in the note yet stays put.
        if rows.contains(where: { $0 !== draft && $0.hasUncommittedTyping }) { return }
        if lines != self.lines || rows.filter({ $0 !== draft }).count != lines.count {
            let focused = rows.firstIndex { $0 !== draft && $0.isFocused }
            rows.filter { $0 !== draft }.forEach { $0.removeFromSuperview() }
            for (i, line) in lines.enumerated() {
                let row = EquationRow(list: self, line: line)
                stack.insertArrangedSubview(row, at: i)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                if i == focused { row.focus() }
            }
            self.lines = lines
        }
        for (i, row) in rows.enumerated() where row !== draft {
            let r = i < info.count ? info[i] : ChartModel.Row()
            row.update(color: r.color.map { ChartPalette.nsColor($0, style: style, dark: dark) }, problem: r.problem, editable: editable)
        }
    }

    func focusFirst() {
        if let first = rows.first { first.focus() } else { addRow() }
    }

    /// A blank row at the end, in the note once something's typed in it.
    func addRow(focus: Bool = true) {
        if let draft {
            if focus { draft.focus() }
            return
        }
        let row = EquationRow(list: self, line: ChartBlockEditing.GraphLine(expression: ""))
        row.update(color: nil, problem: nil, editable: true)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        draft = row
        if focus { row.focus() }
    }

    fileprivate func commit(_ row: EquationRow, addNext: Bool) {
        let text = row.text.trimmingCharacters(in: .whitespaces)
        if row === draft {
            draft = nil
            row.removeFromSuperview()
            guard !text.isEmpty else { return }
            var line = row.line
            line.expression = text
            onCommit?(lines + [line], styled ? "Add Equation" : "Add Line")
            if addNext { RunLoop.main.perform { [weak self] in MainActor.assumeIsolated { self?.addRow() } } }
            return
        }
        guard let i = rows.firstIndex(where: { $0 === row }), i < lines.count else { return }
        if text.isEmpty {
            remove(row)
            return
        }
        if text != lines[i].expression {
            var new = lines
            new[i].expression = text
            onCommit?(new, styled ? "Change Equation" : "Change Line")
        }
        if addNext, i == lines.count - 1 { RunLoop.main.perform { [weak self] in MainActor.assumeIsolated { self?.addRow() } } }
    }

    fileprivate func change(_ row: EquationRow, name: String, _ edit: (inout ChartBlockEditing.GraphLine) -> Void) {
        guard let i = rows.firstIndex(where: { $0 === row }), i < lines.count else { return }
        var new = lines
        edit(&new[i])
        onCommit?(new, name)
    }

    fileprivate func remove(_ row: EquationRow) {
        if row === draft {
            draft = nil
            row.removeFromSuperview()
            return
        }
        guard let i = rows.firstIndex(where: { $0 === row }), i < lines.count else { return }
        var new = lines
        new.remove(at: i)
        onCommit?(new, styled ? "Delete Equation" : "Delete Line")
    }

    #if DEBUG
    func debugDump() -> String {
        rows.map { "  [\($0.text)] \($0.problemText)" }.joined(separator: "\n")
    }

    func debugStep(_ kv: [String]) {
        guard kv.count == 2 else { return }
        let rest = kv[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        switch kv[0] {
        case "add": addRow(); draft?.text = kv[1]; if let d = draft { commit(d, addNext: false) }
        case "set": if let i = Int(rest[0]), i < rows.count, rest.count == 2 { rows[i].text = rest[1]; commit(rows[i], addNext: false) }
        case "remove": if let i = Int(kv[1]), i < rows.count { remove(rows[i]) }
        case "color": if let i = Int(rest[0]), i < rows.count { change(rows[i], name: "Color") { $0.color = rest[1] } }
        case "dash": if let i = Int(rest[0]), i < rows.count { change(rows[i], name: "Line Style") { $0.dash = rest[1] == "solid" ? nil : rest[1] } }
        default: break
        }
    }
    #endif
}

private final class EquationRow: NSView, NSTextFieldDelegate {
    private weak var list: EquationList?
    fileprivate var line: ChartBlockEditing.GraphLine
    private let swatch = NSButton()
    private let field = InspectorField()
    private let more: HoverButton
    private let problem = NSTextField(wrappingLabelWithString: "")

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }
    var problemText: String { problem.isHidden ? "" : problem.stringValue }
    var isFocused: Bool { field.currentEditor() != nil }
    var hasUncommittedTyping: Bool { isFocused && text.trimmingCharacters(in: .whitespaces) != line.expression }

    init(list: EquationList, line: ChartBlockEditing.GraphLine) {
        self.list = list
        self.line = line
        more = HoverButton(symbol: list.styled ? "ellipsis.circle" : "minus.circle", label: list.styled ? "Equation Options" : "Delete Line",
                           pointSize: 12, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        field.stringValue = line.expression
        field.placeholderString = list.placeholder
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        field.delegate = self
        field.setAccessibilityLabel(list.styled ? "Equation" : "Line or Curve")

        swatch.isBordered = false
        swatch.imagePosition = .imageOnly
        swatch.target = self
        // A chart's curves take the next color; the swatch says which, to find it by.
        swatch.action = list.styled ? #selector(swatchClicked) : nil
        swatch.setAccessibilityLabel("Color")
        swatch.toolTip = list.styled ? "Color" : "Its color in the chart"

        more.target = self
        more.action = #selector(moreClicked)
        more.toolTip = list.styled ? "Line style, hide or delete" : "Delete Line"

        problem.font = NSFont.systemFont(ofSize: 10)
        problem.textColor = .systemRed
        problem.isSelectable = false
        problem.isHidden = true

        for v in [swatch, field, more, problem] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let fieldLeading = field.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 6)
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor),
            swatch.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 16),
            swatch.heightAnchor.constraint(equalToConstant: 16),
            fieldLeading,
            field.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            more.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            more.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            problem.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            problem.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            problem.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 2),
            problem.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1).withPriority(.defaultHigh),
        ])
        bottomConstraint = field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        bottomConstraint.isActive = true
    }

    private var bottomConstraint: NSLayoutConstraint!

    required init?(coder: NSCoder) { fatalError() }

    func focus() { window?.makeFirstResponder(field) }

    func update(color: NSColor?, problem why: String?, editable: Bool) {
        field.isEditable = editable
        more.isEnabled = editable
        swatch.isEnabled = editable
        swatch.image = Self.swatch(color, hollow: line.hidden || color == nil)
        problem.stringValue = why ?? ""
        problem.isHidden = why == nil
        bottomConstraint.isActive = why == nil
    }

    /// A filled circle in the line's color; hollow when the line draws nothing.
    private static func swatch(_ color: NSColor?, hollow: Bool) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if hollow {
                (color ?? .tertiaryLabelColor).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            } else {
                color?.setFill()
                path.fill()
            }
            return true
        }
    }

    @objc private func swatchClicked() {
        let menu = NSMenu()
        let current = line.color?.lowercased()
        let auto = ClosureMenuItem("Automatic") { [weak self] in self.map { s in s.list?.change(s, name: "Color") { $0.color = nil } } }
        auto.state = current == nil ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        for name in ["Red", "Blue", "Green", "Purple", "Orange", "Black"] {
            let item = ClosureMenuItem(name) { [weak self] in self.map { s in s.list?.change(s, name: "Color") { $0.color = name.lowercased() } } }
            item.image = Self.swatch(ChartColor.named(name).map { ChartPalette.nsColor($0, dark: false) }, hollow: false)
            item.state = current == name.lowercased() ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: swatch.bounds.height + 4), in: swatch)
    }

    @objc private func moreClicked() {
        guard let list else { return }
        guard list.styled else { list.remove(self); return }
        let menu = NSMenu()
        for (title, dash) in [("Solid Line", nil), ("Dashed Line", "dashed"), ("Dotted Line", "dotted")] as [(String, String?)] {
            let item = ClosureMenuItem(title) { [weak self] in self.map { s in s.list?.change(s, name: "Line Style") { $0.dash = dash } } }
            item.state = line.dash == dash ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hidden = line.hidden
        menu.addItem(ClosureMenuItem(hidden ? "Show" : "Hide") { [weak self] in self.map { s in s.list?.change(s, name: hidden ? "Show" : "Hide") { $0.hidden = !hidden } } })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete") { [weak self] in self.map { s in s.list?.remove(s) } })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let movement = obj.userInfo?["NSTextMovement"] as? Int
        list?.commit(self, addNext: movement == NSTextMovement.return.rawValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            field.stringValue = line.expression
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

// MARK: - Points

/// Points typed straight into a chart, no table needed: a row for each with its x and y,
/// and a field under them that takes a point the way it's written on paper, `(3, 4)`,
/// or several at once, `(1, 2), (2, 4)`. Saved in the block as `points:`.
private final class PointList: NSView, NSTextFieldDelegate {
    /// (all the points, undo name)
    var onCommit: (([ChartPoints.Entry], String) -> Void)?

    private let stack = NSStackView()
    private let entry = InspectorField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var points: [ChartPoints.Entry] = []
    private static let hint = "x is across, y is up. Add several at once: (1, 2), (2, 4)."

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        entry.placeholderString = "Add a point, like (3, 4)"
        entry.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        entry.delegate = self
        entry.setAccessibilityLabel("New Points")
        entry.toolTip = Self.hint
        message.font = NSFont.systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.isSelectable = false
        message.stringValue = Self.hint
        for v in [stack, entry, message] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            // Lined up with the rows' fields, before their delete buttons.
            entry.leadingAnchor.constraint(equalTo: leadingAnchor),
            entry.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            entry.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 4),
            message.leadingAnchor.constraint(equalTo: leadingAnchor),
            message.trailingAnchor.constraint(equalTo: trailingAnchor),
            message.topAnchor.constraint(equalTo: entry.bottomAnchor, constant: 4),
            message.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var rows: [PointRow] { stack.arrangedSubviews.compactMap { $0 as? PointRow } }

    func show(_ points: [ChartPoints.Entry], editable: Bool) {
        entry.isEditable = editable
        // Typing that isn't in the note yet stays put.
        if rows.contains(where: { $0.hasUncommittedTyping }) { return }
        if points != self.points || rows.count != points.count {
            rows.forEach { $0.removeFromSuperview() }
            for (i, p) in points.enumerated() {
                let row = PointRow(list: self, point: p, index: i)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            self.points = points
        }
        rows.forEach { $0.isEditable = editable }
    }

    func focusEntry() { window?.makeFirstResponder(entry) }

    private func say(_ problem: String?) {
        message.stringValue = problem ?? Self.hint
        message.textColor = problem == nil ? .secondaryLabelColor : .systemRed
    }

    /// What's typed in the field below the rows, added after them. Return keeps the
    /// keys there for the next one.
    private func commitEntry() {
        let text = entry.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { say(nil); return }
        let parsed = ChartPoints.parse(text)
        guard parsed.problem == nil, !parsed.entries.isEmpty else {
            say(parsed.problem ?? Self.hint)
            NSSound.beep()
            return
        }
        say(nil)
        entry.stringValue = ""
        onCommit?(points + parsed.entries, parsed.entries.count == 1 ? "Add Point" : "Add Points")
    }

    fileprivate func change(_ row: PointRow, x: String, y: String) {
        guard let i = rows.firstIndex(where: { $0 === row }), i < points.count else { return }
        let (x, y) = (x.trimmingCharacters(in: .whitespaces), y.trimmingCharacters(in: .whitespaces))
        if x.isEmpty, y.isEmpty { remove(row); return }
        guard ChartPoints.number(x) != nil, ChartPoints.number(y) != nil else {
            say("x and y each need a number, like 3 or 2.5.")
            NSSound.beep()
            row.revert()
            return
        }
        say(nil)
        var new = points
        new[i] = ChartPoints.Entry(x: x, y: y)
        if new != points { onCommit?(new, "Change Point") }
    }

    fileprivate func remove(_ row: PointRow) {
        guard let i = rows.firstIndex(where: { $0 === row }), i < points.count else { return }
        var new = points
        new.remove(at: i)
        onCommit?(new, "Delete Point")
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === entry else { return }
        commitEntry()
        if obj.userInfo?["NSTextMovement"] as? Int == NSTextMovement.return.rawValue {
            RunLoop.main.perform { [weak self] in MainActor.assumeIsolated { self?.focusEntry() } }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), control === entry {
            entry.stringValue = ""
            say(nil)
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    #if DEBUG
    func debugDump() -> String {
        rows.map { "  x=\($0.x) y=\($0.y)" }.joined(separator: "\n") + "\n  entry: \(message.stringValue)"
    }

    func debugStep(_ kv: [String]) {
        guard kv.count == 2 else { return }
        let rest = kv[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        switch kv[0] {
        case "add": entry.stringValue = kv[1]; commitEntry()
        case "x": if let i = Int(rest[0]), i < rows.count, rest.count == 2 { change(rows[i], x: rest[1], y: rows[i].y) }
        case "y": if let i = Int(rest[0]), i < rows.count, rest.count == 2 { change(rows[i], x: rows[i].x, y: rest[1]) }
        case "remove": if let i = Int(kv[1]), i < rows.count { remove(rows[i]) }
        default: break
        }
    }
    #endif
}

/// One point: `x [3]  y [4]` and a delete button.
private final class PointRow: NSView, NSTextFieldDelegate {
    private weak var list: PointList?
    private let point: ChartPoints.Entry
    private let xField = InspectorField()
    private let yField = InspectorField()
    private let delete = HoverButton(symbol: "minus.circle", label: "Delete Point", pointSize: 12, target: nil, action: nil)

    var x: String { xField.stringValue }
    var y: String { yField.stringValue }
    var isEditable = true {
        didSet {
            xField.isEditable = isEditable
            yField.isEditable = isEditable
            delete.isEnabled = isEditable
        }
    }
    var hasUncommittedTyping: Bool {
        (xField.currentEditor() != nil || yField.currentEditor() != nil) && (x != point.x || y != point.y)
    }

    init(list: PointList, point: ChartPoints.Entry, index: Int) {
        self.list = list
        self.point = point
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let xLabel = InspectorStyle.label("x"), yLabel = InspectorStyle.label("y")
        xLabel.toolTip = "Across"
        yLabel.toolTip = "Up"
        for (field, value, name) in [(xField, point.x, "x"), (yField, point.y, "y")] {
            field.stringValue = value
            field.placeholderString = "0"
            field.alignment = .right
            field.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
            field.delegate = self
            field.setAccessibilityLabel("Point \(index + 1) \(name)")
        }
        delete.target = self
        delete.action = #selector(deleteClicked)
        delete.toolTip = "Delete Point"
        for v in [xLabel, xField, yLabel, yField, delete] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            xLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            xLabel.firstBaselineAnchor.constraint(equalTo: xField.firstBaselineAnchor),
            xField.leadingAnchor.constraint(equalTo: xLabel.trailingAnchor, constant: 6),
            xField.centerYAnchor.constraint(equalTo: centerYAnchor),
            yLabel.leadingAnchor.constraint(equalTo: xField.trailingAnchor, constant: 12),
            yLabel.firstBaselineAnchor.constraint(equalTo: yField.firstBaselineAnchor),
            yField.leadingAnchor.constraint(equalTo: yLabel.trailingAnchor, constant: 6),
            yField.centerYAnchor.constraint(equalTo: centerYAnchor),
            yField.widthAnchor.constraint(equalTo: xField.widthAnchor),
            delete.leadingAnchor.constraint(equalTo: yField.trailingAnchor, constant: 4),
            delete.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            delete.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func revert() {
        xField.stringValue = point.x
        yField.stringValue = point.y
    }

    @objc private func deleteClicked() { list?.remove(self) }

    func controlTextDidEndEditing(_ obj: Notification) {
        list?.change(self, x: x, y: y)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            revert()
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

// MARK: - Values written in the chart

/// A chart's own values, as the Charts plugin writes them (`labels:` and `series:`): a
/// field of labels, then a row for each set of values with its name, each list typed
/// with commas as it reads in the Markdown.
private final class InlineDataList: NSView, NSTextFieldDelegate {
    /// (labels, every set of values, undo name)
    var onCommit: (([String], [ChartBlockEditing.InlineSeries], String) -> Void)?

    private let labelsField = InspectorField()
    private let stack = NSStackView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var labels: [String] = []
    private var series: [ChartBlockEditing.InlineSeries] = []
    private var shownLabels = ""
    private static let hint = "Commas between values. Each value goes with the label in its place."

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let labelsTitle = InspectorStyle.label("Labels")
        labelsField.placeholderString = "A, B, C"
        labelsField.delegate = self
        labelsField.setAccessibilityLabel("Labels")
        labelsField.toolTip = "The names along the bottom, or of the slices"
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        message.font = NSFont.systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.isSelectable = false
        message.stringValue = Self.hint
        for v in [labelsTitle, labelsField, stack, message] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            labelsTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            labelsTitle.firstBaselineAnchor.constraint(equalTo: labelsField.firstBaselineAnchor),
            // Lined up with the rows' values, before their delete buttons.
            labelsField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DataRow.nameWidth + 6),
            labelsField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            labelsField.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: labelsField.bottomAnchor, constant: 6),
            message.leadingAnchor.constraint(equalTo: leadingAnchor),
            message.trailingAnchor.constraint(equalTo: trailingAnchor),
            message.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 4),
            message.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var rows: [DataRow] { stack.arrangedSubviews.compactMap { $0 as? DataRow } }

    func show(labels: [String], series: [ChartBlockEditing.InlineSeries], editable: Bool) {
        labelsField.isEditable = editable
        shownLabels = labels.joined(separator: ", ")
        if labelsField.currentEditor() == nil { labelsField.stringValue = shownLabels }
        self.labels = labels
        // Typing that isn't in the note yet stays put.
        if rows.contains(where: { $0.hasUncommittedTyping }) { return }
        if series != self.series || rows.count != series.count {
            // Tabbing from a name to its values commits the name; the keys stay put.
            let focused = rows.enumerated().compactMap { i, row in row.focusedField.map { (i, $0) } }.first
            rows.forEach { $0.removeFromSuperview() }
            for (i, s) in series.enumerated() {
                let row = DataRow(list: self, series: s, index: i)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            self.series = series
            if let (i, field) = focused, i < rows.count { rows[i].focus(field) }
        }
        rows.forEach { $0.isEditable = editable }
    }

    /// A new set of values, named for its place, its values field ready to type in.
    func addSeries() {
        let name = series.isEmpty ? "Values" : "Series \(series.count + 1)"
        onCommit?(labels, series + [ChartBlockEditing.InlineSeries(title: name, data: [])], "Add Values")
        RunLoop.main.perform { [weak self] in MainActor.assumeIsolated { self?.rows.last?.focusValues() } }
    }

    func focusFirst() {
        if let first = rows.first { first.focusValues() } else { window?.makeFirstResponder(labelsField) }
    }

    private func say(_ problem: String?) {
        message.stringValue = problem ?? Self.hint
        message.textColor = problem == nil ? .secondaryLabelColor : .systemRed
    }

    fileprivate func change(_ row: DataRow, title: String, values: String) {
        guard let i = rows.firstIndex(where: { $0 === row }), i < series.count else { return }
        let data = ChartBlockEditing.splitTyped(values)
        if let bad = data.first(where: { !$0.isEmpty && ChartPoints.number($0) == nil }) {
            say("“\(bad)” isn’t a number. Values are numbers, like 3 or 2.5, with commas between them.")
            NSSound.beep()
            row.revert()
            return
        }
        say(nil)
        var new = series
        new[i] = ChartBlockEditing.InlineSeries(title: title.trimmingCharacters(in: .whitespaces), data: data)
        if new != series { onCommit?(labels, new, "Change Values") }
    }

    fileprivate func remove(_ row: DataRow) {
        guard let i = rows.firstIndex(where: { $0 === row }), i < series.count else { return }
        var new = series
        new.remove(at: i)
        onCommit?(labels, new, "Delete Values")
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === labelsField, labelsField.stringValue != shownLabels else { return }
        onCommit?(ChartBlockEditing.splitTyped(labelsField.stringValue), series, "Change Labels")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), control === labelsField {
            labelsField.stringValue = shownLabels
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    #if DEBUG
    func debugDump() -> String {
        "  labels=\(labelsField.stringValue)\n" + rows.map { "  \($0.title)=\($0.values)" }.joined(separator: "\n") + "\n  note: \(message.stringValue)"
    }

    /// `labels=A, B`, `add=`, `name=0=Trial 1`, `values=0=1, 2`, `remove=0`.
    func debugStep(_ kv: [String]) {
        guard kv.count == 2 else { return }
        let rest = kv[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        switch kv[0] {
        case "labels":
            labelsField.stringValue = kv[1]
            controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: labelsField))
        case "add": addSeries()
        case "name": if let i = Int(rest[0]), i < rows.count, rest.count == 2 { change(rows[i], title: rest[1], values: rows[i].values) }
        case "values": if let i = Int(rest[0]), i < rows.count, rest.count == 2 { change(rows[i], title: rows[i].title, values: rest[1]) }
        case "remove": if let i = Int(kv[1]), i < rows.count { remove(rows[i]) }
        default: break
        }
    }
    #endif
}

/// One set of values: `[Trial 1] [3, 5, 2]` and a delete button.
private final class DataRow: NSView, NSTextFieldDelegate {
    static let nameWidth: CGFloat = 76

    private weak var list: InlineDataList?
    private let series: ChartBlockEditing.InlineSeries
    private let nameField = InspectorField()
    private let valuesField = InspectorField()
    private let delete = HoverButton(symbol: "minus.circle", label: "Delete Values", pointSize: 12, target: nil, action: nil)

    var title: String { nameField.stringValue }
    var values: String { valuesField.stringValue }
    var isEditable = true {
        didSet {
            nameField.isEditable = isEditable
            valuesField.isEditable = isEditable
            delete.isEnabled = isEditable
        }
    }
    var hasUncommittedTyping: Bool {
        focusedField != nil && (title != series.title || values != Self.text(series.data))
    }
    /// 0 for the name, 1 for the values, when one has the keys.
    var focusedField: Int? { nameField.currentEditor() != nil ? 0 : valuesField.currentEditor() != nil ? 1 : nil }

    private static func text(_ data: [String]) -> String { data.joined(separator: ", ") }

    init(list: InlineDataList, series: ChartBlockEditing.InlineSeries, index: Int) {
        self.list = list
        self.series = series
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        nameField.stringValue = series.title
        nameField.placeholderString = "Name"
        nameField.setAccessibilityLabel("Name of values \(index + 1)")
        nameField.toolTip = "What these values are, for the legend"
        valuesField.stringValue = Self.text(series.data)
        valuesField.placeholderString = "3, 5, 2"
        valuesField.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        valuesField.setAccessibilityLabel(series.title.isEmpty ? "Values \(index + 1)" : "Values of \(series.title)")
        for field in [nameField, valuesField] { field.delegate = self }
        delete.target = self
        delete.action = #selector(deleteClicked)
        delete.toolTip = "Delete Values"
        for v in [nameField, valuesField, delete] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.widthAnchor.constraint(equalToConstant: Self.nameWidth),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valuesField.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 6),
            valuesField.centerYAnchor.constraint(equalTo: centerYAnchor),
            delete.leadingAnchor.constraint(equalTo: valuesField.trailingAnchor, constant: 4),
            delete.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            delete.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func focusValues() { window?.makeFirstResponder(valuesField) }
    func focus(_ field: Int) { window?.makeFirstResponder(field == 0 ? nameField : valuesField) }

    func revert() {
        nameField.stringValue = series.title
        valuesField.stringValue = Self.text(series.data)
    }

    @objc private func deleteClicked() { list?.remove(self) }

    func controlTextDidEndEditing(_ obj: Notification) {
        list?.change(self, title: title, values: values)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            revert()
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}
