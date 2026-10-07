import AppKit

/// The open-source work Indium is built on, shown in the About panel.
enum Acknowledgements {
    private struct Credit {
        let name: String
        let use: String
        let copyright: String
        let license: String
        let link: String
    }

    private static var credits: [Credit] {
        var list = [
            Credit(name: "SwiftMath", use: "Typesets equations.",
                   copyright: "Copyright © 2023 Computer Inspirations; portions © 2013 MathChat (iosMath).",
                   license: "MIT License", link: "https://github.com/mgriebling/SwiftMath/blob/main/LICENSE"),
            Credit(name: "Latin Modern Math", use: "The font equations are set in.",
                   copyright: "Copyright © 2012–2014 B. Jackowski, P. Strzelczyk and P. Pianowski, on behalf of TeX users groups.",
                   license: "GUST Font License", link: "https://tug.org/fonts/licenses/GUST-FONT-LICENSE.txt"),
            Credit(name: "Obsidian LaTeX Suite", use: "Indium's default math shortcuts are adapted from its snippets.",
                   copyright: "Copyright © 2022 artisticat1.",
                   license: "MIT License", link: "https://github.com/artisticat1/obsidian-latex-suite/blob/main/LICENSE.md"),
        ]
        #if !APPSTORE
        list.append(Credit(name: "Sparkle", use: "Keeps Indium up to date.",
                           copyright: "Copyright © 2006–2013 Andy Matuschak, © 2009–2013 Elgato Systems GmbH, © 2011–2014 Kornel Lesiński, © 2015–2017 Mayur Pawashe, and others.",
                           license: "MIT License, with the licenses of the code it includes",
                           link: "https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE"))
        #endif
        return list
    }

    private static let mit = """
        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """

    /// The About panel's credits: each project, its license, and a link to the license
    /// text, then the MIT license itself.
    static var text: NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 2
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center]
        let s = NSMutableAttributedString()
        func add(_ string: String, _ attrs: [NSAttributedString.Key: Any] = [:]) {
            s.append(NSAttributedString(string: string, attributes: plain.merging(attrs) { $1 }))
        }
        add("Acknowledgements\n", [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor])
        add("Indium is built with these, with thanks.\n\n")
        for c in credits {
            add("\(c.name)\n", [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor])
            add("\(c.use) \(c.copyright)\n")
            add(c.license, [.link: URL(string: c.link) as Any])
            add("\n\n")
        }
        add("MIT License\n", [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor])
        add(mit + "\n")
        return s
    }

    static func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: text])
        NSApp.activate()
    }
}
