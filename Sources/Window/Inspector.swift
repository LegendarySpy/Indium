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
            guard let self, let editor = self.editor, case let .chart(location) = editor.inspectorContext else { return }
            editor.changeChart(at: location, actionName: name, edit)
        }
        chart.onEditSource = { [weak self] in
            guard let self, let editor = self.editor, case let .chart(location) = editor.inspectorContext else { return }
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
        switch editor.inspectorContext {
        case .note: titleLabel.stringValue = "Note"
        case .table: titleLabel.stringValue = "Table"
        case let .chart(location):
            if let info = editor.styler.chart(at: location, in: editor.storage) {
                let graph = info.language.lowercased() == "desmos-graph"
                titleLabel.stringValue = graph ? "Graph" : "Chart"
                chart.show(graph: graph, body: info.body, model: info.model, columns: info.columns, editable: editor.textView.isEditable)
                chart.isHidden = false
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
/// read each. Names and values are edited in place; a new one starts as a blank row.
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
    /// A row added with + that isn't in the note until it has a name and a value.
    private var draft: VariableRow?

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

        empty.stringValue = "Numbers in the note’s frontmatter, like mass: 2.008 g, can be used by name in formulas and quick answers."
        for label in [empty, others, message] {
            label.font = NSFont.systemFont(ofSize: 11)
            // System label colors: they stay readable on the glass in light and dark.
            label.textColor = .secondaryLabelColor
            label.isSelectable = false
        }
        message.textColor = .systemRed
        message.isHidden = true

        let column = NSStackView(views: [header, message, rows, empty, others])
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
        for v in [header, rows, empty, others, message] as [NSView] {
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
        let current = rows.arrangedSubviews.compactMap { $0 as? VariableRow }
        if current.contains(where: { $0 !== draft && $0.hasUncommittedTyping }) { return }
        let variables = entries.filter { $0.quantity != nil }
        let changed = variables.map { [$0.name, $0.value] } != shown.map { [$0.name, $0.value] }
        shown = variables
        if changed {
            let focused = current.first { $0 !== draft && $0.focusedField != nil }.map { ($0.originalName, $0.focusedField!) }
            current.filter { $0 !== draft }.forEach { $0.removeFromSuperview() }
            for (i, entry) in variables.enumerated() {
                let row = VariableRow(name: entry.name, value: entry.value, delegate: self)
                rows.insertArrangedSubview(row, at: i)
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                if let (name, field) = focused, name == entry.name { field == .name ? row.focusName() : row.focusValue() }
            }
        }
        for case let row as VariableRow in rows.arrangedSubviews where row !== draft {
            row.isEditable = editable
            let uses = VariableEditing.uses(of: row.originalName, in: text)
            row.uses = uses == 0 ? "" : uses == 1 ? "1 formula" : "\(uses) formulas"
        }
        empty.isHidden = !variables.isEmpty || draft != nil
        let skipped = entries.compactMap { entry -> String? in
            switch entry.status {
            case .variable: return nil
            case .overridden: return "\(entry.name): set again below"
            case let .skipped(why): return "\(entry.name): \(why.lowercased())"
            }
        }
        others.stringValue = skipped.isEmpty ? "" : "Not variables: " + skipped.joined(separator: "; ")
        others.isHidden = skipped.isEmpty
    }

    func focusFirst() {
        if let row = rows.arrangedSubviews.first as? VariableRow { row.focusValue() } else { addClicked() }
    }

    @objc private func addClicked() {
        if let draft { draft.focusName(); return }
        let row = VariableRow(name: "", value: "", delegate: self)
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        draft = row
        empty.isHidden = true
        row.focusName()
    }

    private func say(_ problem: String?) {
        message.stringValue = problem ?? ""
        message.isHidden = problem == nil
        if problem != nil { NSSound.beep() }
    }

    // MARK: Committing

    /// A field of `row` was left: put its change in the note, or say why it can't go in.
    fileprivate func commit(_ row: VariableRow, field: VariableRow.Field) {
        let name = row.name.trimmingCharacters(in: .whitespaces)
        let value = row.value.trimmingCharacters(in: .whitespaces)
        if row === draft {
            if name.isEmpty && value.isEmpty, field == .value { discardDraft(); return }
            // Wait for both halves before writing anything.
            guard !name.isEmpty, !value.isEmpty else { return }
            guard let problem = problem(name: name, value: value, replacing: nil) else {
                say(nil)
                if onChange?("Add Variable", { VariableEditing.setting(name, to: value, in: $0) }) == true {
                    // The note has it now: the next read shows it as an ordinary row.
                    draft = nil
                    row.removeFromSuperview()
                    shown = []
                } else {
                    say("Couldn’t add “\(name)” to the frontmatter")
                }
                return
            }
            say(problem)
            return
        }
        switch field {
        case .name:
            guard name != row.originalName else { say(nil); return }
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
            if Evaluator.isReserved(name) { return "“\(name)” is a function or constant. Try another name." }
            if !VariableEditing.isValidName(name) { return "Names start with a letter or _, then letters, digits or _." }
            if name != replacing, shown.contains(where: { $0.name == name }) { return "There’s already a variable named “\(name)”." }
        }
        if let value, Quantity.parse(value) == nil || value.hasPrefix("*") || value.hasPrefix("_") {
            return "“\(value)” isn’t a number. Write it like 2.008, 2.008 g or 85%."
        }
        return nil
    }

    private func discardDraft() {
        draft?.removeFromSuperview()
        draft = nil
        say(nil)
        empty.isHidden = !shown.isEmpty
    }

    fileprivate func delete(_ row: VariableRow) {
        say(nil)
        if row === draft { discardDraft(); return }
        let old = row.originalName
        _ = onChange?("Delete Variable") { VariableEditing.removing(old, in: $0) }
    }

    fileprivate func cancel(_ row: VariableRow) {
        say(nil)
        if row === draft { discardDraft() } else { row.revert() }
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
            addClicked()
            if let d = draft, kv.count == 2 { d.name = kv[0]; commit(d, field: .name); d.value = kv[1]; commit(d, field: .value) }
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
        nameField.placeholderString = "name"
        nameField.setAccessibilityLabel("Variable Name")
        valueField.stringValue = value
        valueField.placeholderString = "value, like 2.5 g"
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
    private let titleField = InspectorField()
    private let xTitle = InspectorField()
    private let yTitle = InspectorField()
    private let seriesHeader = SectionHeader(title: "Columns")
    private let series = NSStackView()
    private let optionsHeader = SectionHeader(title: "Options")
    private let bestFit = NSButton(checkboxWithTitle: "Line of best fit", target: nil, action: nil)
    private let zero = NSButton(checkboxWithTitle: "Start y at zero", target: nil, action: nil)
    private let legend = NSButton(checkboxWithTitle: "Legend", target: nil, action: nil)
    private let curvesHeader = SectionHeader(title: "Curves")
    private let curves = EquationList(styled: false, placeholder: "y = 0.35x + 94")
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

        type.addItems(withTitles: ["Line", "Bar", "Scatter"])
        type.controlSize = .small
        type.font = InspectorStyle.font
        type.target = self
        type.action = #selector(typeChanged)
        type.setAccessibilityLabel("Chart Type")
        for (field, key, label) in [(titleField, "title", "Title"), (xTitle, "xTitle", "X Axis Title"), (yTitle, "yTitle", "Y Axis Title"),
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
        for label in [source, problems] {
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
        curvesHeader.addButton.toolTip = "Add Curve"
        curvesHeader.addButton.setAccessibilityLabel("Add Curve")
        for header in [rangeHeader, seriesHeader, optionsHeader] { header.addButton.isHidden = true }

        equations.onCommit = { [weak self] lines, name in
            self?.onEdit?(name) { ChartBlockEditing.settingGraphLines(lines, in: $0) }
        }
        curves.onCommit = { [weak self] lines, name in
            self?.onEdit?(name) { ChartBlockEditing.settingPlots(lines.map(\.expression), in: $0) }
        }

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        let views: [NSView] = [equationsHeader, equations, rangeHeader, rangeGrid, gridLines,
                               chartGrid, seriesHeader, series, optionsHeader, options, curvesHeader, curves,
                               problems, source, editSource]
        for v in views { column.addArrangedSubview(v) }
        for v in [equations, rangeGrid, chartGrid, curves] { column.setCustomSpacing(16, after: v) }
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
        for v in [equationsHeader, equations, rangeHeader, chartGrid, seriesHeader, optionsHeader, curvesHeader, curves, problems, source] as [NSView] {
            v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        // Its fields end where the equations' fields do, before their menu buttons.
        rangeGrid.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -20).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(graph: Bool, body: String, model: ChartModel, columns: [String], editable: Bool) {
        self.graph = graph
        for v in [equationsHeader, equations, rangeHeader, rangeGrid, gridLines] as [NSView] { v.isHidden = !graph }
        for v in [chartGrid, optionsHeader, bestFit.superview!, curvesHeader] as [NSView] { v.isHidden = graph }
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
            equations.show(lines: ChartBlockEditing.graphLines(body), rows: model.rows, dark: dark, editable: editable)
            equationsHeader.addButton.isEnabled = editable
            unplaced = model.problems.filter { p in !ChartBlockEditing.graphLines(body).contains { p.hasPrefix($0.expression + ":") } }
            source.stringValue = "Equations use LaTeX, as in Desmos. Note variables work by name."
            seriesHeader.isHidden = true
            series.isHidden = true
            curves.isHidden = true
        } else {
            let s = ChartBlockEditing.chartSettings(body)
            let kind = s["type"]?.lowercased() ?? "line"
            let known = ["line", "bar", "scatter"]
            type.selectItem(at: known.firstIndex(of: kind) ?? 0)
            type.isEnabled = editable && known.contains(kind)
            set(titleField, s["title"], placeholder: "None")
            set(xTitle, s["xTitle"], placeholder: model.xTitle ?? "None")
            set(yTitle, s["yTitle"], placeholder: model.yTitle ?? "None")
            bestFit.state = s["bestFit"]?.lowercased() == "true" ? .on : .off
            zero.state = s["beginAtZero"]?.lowercased() == "true" ? .on : .off
            legend.state = s["legend"]?.lowercased() == "false" ? .off : .on
            for b in [bestFit, zero, legend] { b.isEnabled = editable }
            showSeries(columns: columns, selected: MiniYAML.parse(body)["select"]?.list, editable: editable)
            let plots = ChartBlockEditing.plots(body)
            curves.show(lines: plots.map { ChartBlockEditing.GraphLine(expression: $0) }, rows: model.rows, dark: dark, editable: editable)
            curves.isHidden = plots.isEmpty && !curves.hasDraft
            curvesHeader.addButton.isEnabled = editable
            unplaced = model.problems.filter { p in !plots.contains { p.hasPrefix($0 + ":") } }
            source.stringValue = s["id"].map { "Data from the table marked ^\($0)." } ?? "Data written in the chart’s Markdown."
        }
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
        setting("Chart Type", "type", ["line", "bar", "scatter"][max(0, type.indexOfSelectedItem)])
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
        setting(graph ? "Graph Range" : "Chart Title", key, value.isEmpty ? nil : value)
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
              : "chart type=\(type.titleOfSelectedItem ?? "") title=\(titleField.stringValue) x=\(xTitle.stringValue)|\(xTitle.placeholderString ?? "") y=\(yTitle.stringValue)|\(yTitle.placeholderString ?? "") fit=\(bestFit.state == .on) columns=\(columns) selected=\(selected)\n" + curves.debugDump()
    }

    /// `type:Bar`, `fit`, `field:key=value`, `eq:add=y=2x`, `eq:set=0=y=3x`, `eq:remove=0`,
    /// `eq:color=0=red`, `eq:dash=0=dashed`, `curve:add=y=x`, `column:Volume`.
    func debugStep(_ step: String) {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let kv = parts.count == 2 ? parts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init) : []
        switch parts[0] {
        case "type": type.selectItem(withTitle: parts[1]); typeChanged()
        case "fit": bestFit.performClick(nil)
        case "field":
            guard kv.count == 2, let field = fieldKeys.first(where: { $0.value == kv[0] }).flatMap({ key in
                [titleField, xTitle, yTitle, left, right, bottom, top].first { ObjectIdentifier($0) == key.key } }) else { return }
            field.stringValue = kv[1]
            controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        case "eq": equations.debugStep(kv)
        case "curve": curves.debugStep(kv)
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

    func show(lines: [ChartBlockEditing.GraphLine], rows info: [ChartModel.Row], dark: Bool, editable: Bool) {
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
            row.update(color: r.color.map { ChartPalette.nsColor($0, dark: dark) }, problem: r.problem, editable: editable)
        }
    }

    func focusFirst() {
        if let first = rows.first { first.focus() } else { addRow() }
    }

    /// A blank row at the end, in the note once something's typed in it.
    func addRow() {
        if let draft { draft.focus(); return }
        let row = EquationRow(list: self, line: ChartBlockEditing.GraphLine(expression: ""))
        row.update(color: nil, problem: nil, editable: true)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        draft = row
        row.focus()
    }

    fileprivate func commit(_ row: EquationRow, addNext: Bool) {
        let text = row.text.trimmingCharacters(in: .whitespaces)
        if row === draft {
            draft = nil
            row.removeFromSuperview()
            guard !text.isEmpty else { return }
            var line = row.line
            line.expression = text
            onCommit?(lines + [line], styled ? "Add Equation" : "Add Curve")
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
            onCommit?(new, styled ? "Change Equation" : "Change Curve")
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
        onCommit?(new, styled ? "Delete Equation" : "Delete Curve")
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
        more = HoverButton(symbol: list.styled ? "ellipsis.circle" : "minus.circle", label: list.styled ? "Equation Options" : "Delete Curve",
                           pointSize: 12, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        field.stringValue = line.expression
        field.placeholderString = list.placeholder
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        field.delegate = self
        field.setAccessibilityLabel(list.styled ? "Equation" : "Curve")

        swatch.isBordered = false
        swatch.imagePosition = .imageOnly
        swatch.target = self
        swatch.action = #selector(swatchClicked)
        swatch.setAccessibilityLabel("Color")
        swatch.toolTip = "Color"
        swatch.isHidden = !list.styled

        more.target = self
        more.action = #selector(moreClicked)
        more.toolTip = list.styled ? "Line style, hide or delete" : "Delete Curve"

        problem.font = NSFont.systemFont(ofSize: 10)
        problem.textColor = .systemRed
        problem.isSelectable = false
        problem.isHidden = true

        for v in [swatch, field, more, problem] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let fieldLeading = list.styled ? field.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 6)
                                       : field.leadingAnchor.constraint(equalTo: leadingAnchor)
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
