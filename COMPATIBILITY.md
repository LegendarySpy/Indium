# Compatibility

Indium opens an Obsidian vault as it is and writes plain Markdown back. This page lists what it understands, what it leaves alone, and where it behaves differently. Anything Indium doesn't understand stays in the file exactly as written.

## Obsidian Markdown

**Supported**

- CommonMark basics: headings, lists and task lists, quotes, code blocks, links, images, horizontal rules, pipe tables.
- `==highlights==`, `~~strikethrough~~`, YAML frontmatter, and `icon:` in frontmatter for a note's icon.
- `[[Wiki links]]`, with `|aliases`. A link to `[[Note#Heading]]` opens the note.
- Images on a line of their own, `![[image.png]]` or `![](image.png)`, with a width (`![[image.png|300]]`).
- `![[Note]]` embeds, including `![[Note#Heading]]` and `![[Note#^block]]`. Nested embeds go two levels deep, and a note that embeds itself (directly or in a loop) shows as a link.
- Callouts (`> [!note] Title`), with folding (`[!tip]-` starts closed, `[!tip]+` open).
- `#tags`, shown as small pills.
- `%% comments %%`, hidden until you edit them.
- Footnotes: `[^1]` references raised, with the note's text on hover, and `[^1]: …` definitions set apart.
- `$inline$` and `$$display$$` math.
- A few HTML tags notes use: `<br>`, `<sup>`, `<sub>`, `<u>`, `<mark>`, `<kbd>`.

**Limits**

- Embeds work only on a line of their own. `![[Note]]` in the middle of a sentence stays a link.
- Only notes are embedded. PDFs, audio, video, canvases and bases stay links.
- A `%%` comment that starts partway through a line and runs onto later lines isn't treated as a comment. Comments on one line, or starting a line, are.
- Inline footnotes (`^[text]`) are shown small and dimmed where they're written, but not numbered.
- Callouts are recognized at the top level only. A callout inside a quote or another callout reads as a quote.
- No Dataview, Mermaid, canvases, or plugin syntax. It's kept as written.

## LaTeX Suite

Indium's math shortcuts follow Obsidian's [LaTeX Suite](https://github.com/artisticat1/obsidian-latex-suite) (MIT License, Copyright (c) 2022 artisticat1). The default shortcuts are adapted from its default snippets.

**Supported**

- The default snippets, auto-fractions (`x/` → `\frac{x}{}`), and auto-enlarged brackets around fractions, sums and integrals.
- Tabstops (`$0`, `$1`, `${1:text}`), with repeated numbers mirrored, and Shift-Tab back.
- Matrices: Tab adds `&`, Return adds `\\`, Shift-Return leaves.
- Typing over a selection in math wraps it (`(`, `/`, and the other built-in wrappers).
- A live preview under inline math.
- The same shortcuts in table cells, except for ones that need several lines.
- Your own snippets in `.indium/snippets.json` in the notes folder (or Indium's Application Support folder when no folder is open), in LaTeX Suite's format: a list of `{trigger, replacement, options, priority}`. LaTeX Suite's whole `data.json` works too. Options: `m` `M` `n` `t` for where, `A` for automatic, `r` regex (with `[[0]]` captures), `w` whole word. A file with mistakes keeps the built-in shortcuts and says what's wrong.

**Differences and gaps**

- No JavaScript: snippets whose replacement is a function are skipped, with a note.
- No visual snippets of your own (`v` option). Only the built-in wrappers work on a selection.
- Tab leaves an equation from anywhere in the line. LaTeX Suite only does this at the end of a line.
- No conceal mode. Equations are typeset in place instead when the caret leaves them.
- mhchem's `\ce{…}` and `\pu{…}` don't typeset. The source is kept as written, so Obsidian still renders it. In Indium, write formulas with subscripts: `CuSO_{4}\cdot 5H_{2}O`.

## Table formulas

Table formulas are Advanced Tables' `<!-- TBLFM: … -->` lines, right under a table. Indium evaluates a subset of them, and adds a few things Advanced Tables can't evaluate. The full reference is in [`Sources/Formulas/README.md`](Sources/Formulas/README.md).

**Shared with Advanced Tables**

- References: `@2`, `$3`, `@>`, `$<`, `@I`, relative `@-1`, `$+1`, and ranges like `@2..@4`.
- Destinations: a cell, a row, a column, or a range of cells.
- `sum` and `mean`, numbers, and arithmetic where every operation has its own parentheses: `((@4/@2)*100)`.
- `::` to chain formulas, several TBLFM lines, and `;%.1f` to set the decimals.

**Indium only** (Advanced Tables can't parse a line that uses these, so keep them on a line of their own)

- Variables from the note's frontmatter, by name: `(@4/water_molar_mass)`.
- `min`, `max`, `count`, comma arguments, and `sqrt sin cos tan log ln abs`.
- Units (`2.008 g − 0.715 g = 1.293 g`) and significant figures. Advanced Tables drops units and prints full precision.

**Different on purpose**

- A blank input leaves the result blank, instead of counting as 0.
- All or nothing: if any formula has a problem, no cell changes, and the table says why.
- Formulas run in dependency order, like a spreadsheet, so running them twice changes nothing.

**Not supported:** `if(…)` and comparisons, dates and times (`;dt`, `;hm`). Those lines are kept exactly as written.

## Quick Look

Press Space on a note in Finder to see it rendered.

- **Direct download:** the note, with images and embedded notes. Quick Look looks for an embedded note beside the previewed one, then in the folders above it up to the vault's root. A note it doesn't find there stays a link (it doesn't search the whole vault).
- **App Store edition:** the note's own text only. The sandbox lets Quick Look read just the note you're previewing, so images show a placeholder saying they can't be shown in Quick Look, and embedded notes stay links. It never asks for more access. Open the note in Indium to see everything.

## App Store edition

The App Store edition keeps its own settings and note icons, separate from the direct download:

- It asks for your notes folder once, and remembers it.
- On first launch it copies your note icons from the direct download, leaving the original file as it is. If the sandbox won't let it read them, it offers once to import them; Settings has the same button for later. Icons you've already chosen in the App Store edition are kept.
