import AppKit

extension NSAttributedString.Key {
    /// Character is not drawn and takes no space (syntax hidden while not editing).
    static let mdHidden = NSAttributedString.Key("indium.hidden")
    /// Rendered inline equation covering the whole `$...$` span.
    static let mdInlineMath = NSAttributedString.Key("indium.inlineMath")
    /// Block render (display equation or image) anchored to a line.
    static let mdBlock = NSAttributedString.Key("indium.block")
    /// Decoration drawn behind a group of lines (code block box, quote bar).
    static let mdGroup = NSAttributedString.Key("indium.group")
    /// List bullet drawn in place of `-`, `*` or `+`; value is the nesting depth.
    static let mdBullet = NSAttributedString.Key("indium.bullet")
    /// Rounded background behind inline code or highlighted text.
    static let mdInlineBox = NSAttributedString.Key("indium.inlineBox")
    /// Horizontal rule.
    static let mdRule = NSAttributedString.Key("indium.rule")
    /// A page break written into the note, drawn as a labeled dashed line.
    static let mdPageBreak = NSAttributedString.Key("indium.pageBreak")
    /// Another note shown under an `![[Note]]` line, drawn in a bordered box.
    static let mdEmbed = NSAttributedString.Key("indium.embed")
    /// A callout's icon, default title and fold chevron, on its first character.
    static let mdCallout = NSAttributedString.Key("indium.callout")
    /// A hidden `<br>` whose first character breaks the line.
    static let mdLineBreak = NSAttributedString.Key("indium.lineBreak")
    /// A one-line caption drawn in place of hidden source (a table's formula lines).
    static let mdCaption = NSAttributedString.Key("indium.caption")
}

final class CaptionDecoration: NSObject {
    let text: String
    let isError: Bool
    /// A link after the text ("Recalculate"); clicking the caption does it.
    let action: String?
    init(text: String, isError: Bool, action: String? = nil) {
        self.text = text
        self.isError = isError
        self.action = action
    }
}

final class InlineMath: NSObject {
    let render: MathRender
    static let padding: CGFloat = 1.5
    /// Followed by punctuation: no trailing padding, and the typesetter's rounding and
    /// space-after-script trimmed, so "HNO₃." doesn't read as "HNO₃ .".
    let tightAfter: Bool
    var advance: CGFloat {
        guard tightAfter else { return render.width + Self.padding * 2 }
        return max(render.width - 1, 1) + Self.padding
    }
    init(render: MathRender, tightAfter: Bool = false) {
        self.render = render
        self.tightAfter = tightAfter
    }
}

final class BlockDecoration: NSObject {
    enum Placement: Equatable {
        case replace, below
        /// Beside the text that follows it, which wraps around it.
        case float(right: Bool)
    }
    enum Content {
        case math(MathRender, scale: CGFloat)
        case image(NSImage?, size: NSSize, caption: String?, name: String)
        case table(TableRender)
    }
    let content: Content
    let placement: Placement
    /// Height of the reserved area, including vertical padding.
    let height: CGFloat
    let padding: CGFloat
    var isSelected = false

    init(content: Content, placement: Placement, height: CGFloat, padding: CGFloat) {
        self.content = content
        self.placement = placement
        self.height = height
        self.padding = padding
    }
}

final class GroupDecoration: NSObject {
    enum Kind {
        case code, quote(depth: Int)
        /// A line of a callout of this type (as written). Lines of one callout compare
        /// equal, so the box is found as one run however its lines were styled.
        case callout(String)
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    override func isEqual(_ object: Any?) -> Bool {
        if case let .callout(a) = kind, let other = object as? GroupDecoration, case let .callout(b) = other.kind { return a == b }
        return super.isEqual(object)
    }
    override var hash: Int {
        if case let .callout(type) = kind { return type.hashValue }
        return super.hash
    }
}

/// What a callout's first line shows besides its text: the type's icon, the type's
/// name when no title is written, and a chevron when it folds.
final class CalloutMark: NSObject {
    let look: CalloutLook
    let defaultTitle: String?
    let font: NSFont
    let foldable: Bool
    let folded: Bool
    init(look: CalloutLook, defaultTitle: String?, font: NSFont, foldable: Bool, folded: Bool) {
        self.look = look
        self.defaultTitle = defaultTitle
        self.font = font
        self.foldable = foldable
        self.folded = folded
    }
}

/// Obsidian's callout types and aliases, each with a tint and an icon.
struct CalloutLook {
    let title: String
    let symbol: String
    let color: NSColor

    static func of(_ type: String) -> CalloutLook {
        let blue = NSColor.dynamic(light: NSColor(hex: 0x3F72B5), dark: NSColor(hex: 0x7EA8DE))
        let cyan = NSColor.dynamic(light: NSColor(hex: 0x23919C), dark: NSColor(hex: 0x5EC3CC))
        let green = NSColor.dynamic(light: NSColor(hex: 0x3A8F55), dark: NSColor(hex: 0x6CC487))
        let orange = NSColor.dynamic(light: NSColor(hex: 0xC27722), dark: NSColor(hex: 0xE2A35C))
        let red = NSColor.dynamic(light: NSColor(hex: 0xBF4B44), dark: NSColor(hex: 0xE5807A))
        let purple = NSColor.dynamic(light: NSColor(hex: 0x7F5BB8), dark: NSColor(hex: 0xB394E3))
        let gray = NSColor.dynamic(light: NSColor(hex: 0x7D7872), dark: NSColor(hex: 0xA8A39D))
        let name = type.prefix(1).uppercased() + type.dropFirst()
        switch type {
        case "abstract", "summary", "tldr": return CalloutLook(title: name, symbol: "list.bullet.clipboard", color: cyan)
        case "info": return CalloutLook(title: name, symbol: "info.circle", color: blue)
        case "todo": return CalloutLook(title: name, symbol: "checkmark.circle", color: blue)
        case "tip", "hint", "important": return CalloutLook(title: name, symbol: "flame", color: cyan)
        case "success", "check", "done": return CalloutLook(title: name, symbol: "checkmark", color: green)
        case "question", "help", "faq": return CalloutLook(title: name, symbol: "questionmark.circle", color: orange)
        case "warning", "caution", "attention": return CalloutLook(title: name, symbol: "exclamationmark.triangle", color: orange)
        case "failure", "fail", "missing": return CalloutLook(title: name, symbol: "xmark", color: red)
        case "danger", "error": return CalloutLook(title: name, symbol: "bolt", color: red)
        case "bug": return CalloutLook(title: name, symbol: "ladybug", color: red)
        case "example": return CalloutLook(title: name, symbol: "list.bullet", color: purple)
        case "quote", "cite": return CalloutLook(title: name, symbol: "quote.opening", color: gray)
        // `note` and any type Obsidian doesn't know look like a note, keeping their name.
        default: return CalloutLook(title: name, symbol: "pencil", color: blue)
        }
    }
}

enum InlineBoxKind { case code, highlight, tag, key }

final class InlineBox: NSObject {
    let kind: InlineBoxKind
    init(_ kind: InlineBoxKind) { self.kind = kind }
}

protocol ImageResolving: AnyObject {
    func image(for ref: ImageRef) -> NSImage?
}

/// Finds the notes `![[Note]]` lines embed. Image resolvers that also adopt this get
/// embedded notes drawn; others show the line as a plain link.
protocol NoteEmbedResolving: AnyObject {
    /// The note being styled, so it never embeds itself.
    var embeddingNoteURL: URL? { get }
    /// The note a wiki target names, resolved the way wiki links are from `note`.
    func noteURL(forEmbed target: String, from note: URL?) -> URL?
    /// An image written in `note`, resolved from that note's folder.
    func image(for ref: ImageRef, from note: URL?) -> NSImage?
    /// Whether a note it can't find shows as "Note not found". Quick Look sees only part
    /// of the disk, so there an embed it can't read stays a plain link.
    var showsMissingEmbeds: Bool { get }
}

extension NoteEmbedResolving {
    var showsMissingEmbeds: Bool { true }
}

/// Resolves links and images inside an embedded note from that note's own folder,
/// through the editor's (or Quick Look's) resolver.
final class EmbeddedNoteContext: ImageResolving, NoteEmbedResolving {
    let root: NoteEmbedResolving
    let note: URL
    init(root: NoteEmbedResolving, note: URL) {
        self.root = root
        self.note = note
    }
    var embeddingNoteURL: URL? { note }
    func noteURL(forEmbed target: String, from note: URL?) -> URL? { root.noteURL(forEmbed: target, from: note) }
    func image(for ref: ImageRef, from note: URL?) -> NSImage? { root.image(for: ref, from: note) }
    func image(for ref: ImageRef) -> NSImage? { root.image(for: ref, from: note) }
    var showsMissingEmbeds: Bool { root.showsMissingEmbeds }
}
