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
- No Dataview, Mermaid, canvases, or plugin syntax, apart from the Charts and Desmos plugins' blocks (below). It's kept as written.

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

In Indium you type a formula in a cell the way you would in a spreadsheet, `=B2-B3` or `=SUM(B2:B5)`. The note stores it as Advanced Tables' `<!-- TBLFM: … -->` lines, right under the table, and the results as plain cell text, so Obsidian shows the values and Advanced Tables can recalculate them. Indium evaluates a subset of TBLFM, and adds a few things Advanced Tables can't evaluate. The full reference is in [`Sources/Formulas/README.md`](Sources/Formulas/README.md).

**Shared with Advanced Tables**

- References: `@2`, `$3`, `@>`, `$<`, `@I`, relative `@-1`, `$+1`, and ranges like `@2..@4`.
- Destinations: a cell, a row, a column, or a range of cells.
- `SUM` and `AVERAGE` (`sum` and `mean`), numbers, and arithmetic. Indium writes every operation in its own parentheses, `((@4/@2)*100)`, as Advanced Tables needs.
- `::` to chain formulas, several TBLFM lines, and `;%.1f` to set the decimals.

**Indium only** (Advanced Tables can't parse a line that uses these, so keep them on a line of their own)

- Variables from the note's frontmatter, by name: `(@4/water_molar_mass)`.
- `MIN`, `MAX`, `COUNT`, `SQRT`, `ABS`, `LN`, `LOG10`, `SIN`, `COS`, `TAN`, `^`, and a `ROUND` that isn't the whole formula (`=ROUND(B4, 1)*2`). A whole-formula `=ROUND(…, 1)` is stored as `;%.1f`, which Advanced Tables reads.
- Units (`2.008 g − 0.715 g = 1.293 g`) and significant figures. Advanced Tables drops units and prints full precision.

**Different on purpose**

- A blank input leaves the result blank, instead of counting as 0.
- All or nothing: if any formula has a problem, no cell changes, and the table says why.
- Formulas run in dependency order, like a spreadsheet, so running them twice changes nothing.

**Not supported:** `IF` and comparisons, text, dates and times (`;dt`, `;hm`). Lines with them are kept exactly as written.

## Charts and graphs

Indium draws two kinds of fenced blocks, in the formats of the Obsidian plugins that already draw them, so a chart made in one app draws in the other. Without the plugin, Obsidian shows the block as code.

**Charts (`chart`), as the [Charts](https://github.com/phibr0/obsidian-charts) plugin writes them**

- `type: line`, `bar`, `pie` and `doughnut`, with data written in the block (`labels`, `series` with `title` and `data`) or read from a table. A pie shows the first set of values.
- A table is named the plugin's way: a `^name` line under it, after a blank line, and `id: name` in the chart. `layout: rows` or `columns` and `select: [...]` work as in the plugin. Make Chart and `/chart` write both for you.
- Also read: `title`, `xTitle`, `yTitle`, `xMin`, `xMax`, `yMin`, `yMax`, `beginAtZero`, `bestFit`, `bestFitTitle`, `bestFitNumber`, `legend`, `stacked`, `spanGaps`, `width`. Other keys are kept and ignored.
- Different on purpose: when every label is a number, the x axis is spaced by value, as a lab graph needs. The plugin spaces labels evenly.
- Indium only: `type: scatter`, `points: (1, 2), (2, 4)` named by `pointsTitle:`, `plot: y = 2x + 1` for a curve over the data, `style: mono`, `vivid`, `hatched`, `gradient` or `dotted` for its look (soft, Indium's own colors, when there's none), values with units (`101.2 kPa`, the unit goes in the axis title), and a best-fit equation with R². The plugin shows the chart without these.
- Not drawn: radar, polar area and sankey charts, Dataview data, and tables in other notes (`file:`). The chart says so.

**Graphs (`desmos-graph`), as the [Desmos](https://github.com/Nigecat/obsidian-desmos) plugin writes them**

- One LaTeX equation per line: `y=` curves, `x=` lines, points `(3,4)`, constants (`k=2`) and functions (`f(x)=…`) that later lines use. Indium draws them itself, offline.
- Settings before `---`: `left`, `right`, `top`, `bottom`, `width`, `height`, `grid`, `degreeMode`, `defaultColor`.
- Flags after `|`: colors, `dashed` and `dotted`, `point`, `open` and `cross`, `hidden`, `label:…`, and restrictions such as `x>0`.
- Indium only: the note's frontmatter variables by name. In Obsidian, define them in the graph (`k=2`) instead.
- Not drawn: implicit curves (`x^2+y^2=1`), inequalities, derivatives, lists, and sliders. The graph lists those lines under it.

## Quick Look

Press Space on a note in Finder to see it rendered.

- **Direct download:** the note, with images and embedded notes. Quick Look looks for an embedded note beside the previewed one, then in the folders above it up to the vault's root. A note it doesn't find there stays a link (it doesn't search the whole vault).
- **App Store edition:** the note's own text only. The sandbox lets Quick Look read just the note you're previewing, so images show a placeholder saying they can't be shown in Quick Look, and embedded notes stay links. It never asks for more access. Open the note in Indium to see everything.

## App Store edition

The App Store edition keeps its own settings and note icons, separate from the direct download:

- It asks for your notes folder once, and remembers it.
- On first launch it copies your note icons from the direct download, leaving the original file as it is. If the sandbox won't let it read them, it offers once to import them; Settings has the same button for later. Icons you've already chosen in the App Store edition are kept.
