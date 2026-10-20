# Inspector, table overhaul and graphs

Draft plan, 2026-10-14. Not started. Builds on `IMPROVEMENT_PLAN.md` (note variables, TBLFM formulas) and lands after 1.1.1 ships.

Decided with Garon:

- **Graphs: both kinds.** Charts drawn from a table's columns, and function plots (`y = k x^2`) that can use note variables. One chart can show both, so measured data and the theoretical curve sit on the same axes.
- **Graphs are saved as fenced blocks** (```` ```chart ````), plain readable lines in the note. No images on disk.
- **A right-side inspector**, the mirror of the left file sidebar, for the technical side of a note: note variables, table columns, formulas and graph settings. The table itself stays the place where you type values. The inspector is where you change how things are set up.

One wording fix to make alongside: the README says Indium "won't have a graph view". That means Obsidian's map of linked notes, and should say so, since charts are now coming.

## 1. The inspector panel

A glass panel docked on the window's right edge, built the way `SidebarView` is in `DocumentWindowController` (blur in and out, page slides over when there's room, floats over the page below `minPageWidth`). With both panels open, the page needs room for both before either pushes it; otherwise the later one floats.

- **Toggle:** a `sidebar.right` button at the right end of the title bar, View menu item "Show Inspector", ⌥⌘I. Remembered like `showSidebar`.
- **Every window kind gets it**, temporary and file windows included. Nothing in it needs the vault.
- **Follows the caret.** Caret in a table (or the table editor open): Table and Formulas. Caret in a chart block, or the chart clicked: Graph. Anywhere else: Note. Variables are always reachable, collapsed when a table or graph is showing.
- **Every change is one undo step on the note**, through the same paths the editor already uses (the table editor's `onChange`, text replacement for frontmatter and chart blocks). The inspector never keeps state of its own that the note doesn't have, so external edits (file watcher, AI agents) just refresh it.
- **Built in AppKit**, like the sidebar and table toolbar. SwiftUI is only used for Settings today; small forms could go either way, but keyboard focus and first-responder handoff with the text view are easier to get right in AppKit.
- **Accessibility and keyboard:** every field reachable with Tab, Escape returns to the note, VoiceOver labels on every control.

### Note: variables

The frontmatter numbers `NoteVariables` already reads (`hydrated: 2.008 g`).

- A list of name, value, unit. Add, edit, rename, delete.
- Shows where each is used ("2 formulas"), and which frontmatter lines were skipped and why (not a number, reserved name like `pi`), using the rules in `Variables.swift`.
- **A new frontmatter writer** that changes one line in place: keeps order, quotes, comments and every non-numeric property byte for byte. Creates the `---` block when there isn't one. This is the riskiest part of this section and needs round-trip cases in the self-tests.
- Renaming a variable offers to update the formulas and chart blocks that use it.

## 2. The table overhaul (inspector side)

Per your note, this is the technical side, not the grid. The grid changes are limited to keeping it in sync with the inspector: selecting a column or cell in the table selects it in the inspector, and hovering a formula in the inspector outlines its cells in the table (the outline code from formula entry already exists).

### Table section

- **Table:** rows and columns count, "first column is labels" (today guessed by `hasLabelColumn`), transpose, sort by a column, Copy as CSV, and "Make Chart" (inserts a chart block under the table, already pointed at it).
- **Selected column:** header text, alignment, width (dash counts, as now), unit, and display precision.

**Open decision: where units and precision live.** Today a unit is in each cell (`2.008 g`) and decimals are a per-formula `;%.3f` directive. Two options:

1. **Only what Markdown already has (recommended for v1).** Setting a column's unit rewrites the cells' suffixes (or the header as `Mass (g)`); precision is offered only on computed columns and stored as the formula's directive. Nothing hidden, nothing Obsidian can't show.
2. **A small table settings comment** under the table next to TBLFM, e.g. `<!-- indium: B unit=g sig=3 -->`. Allows sig figs on typed values too, but it's a new format to maintain and Obsidian ignores it.

### Formulas section

Everything the caption popover lists today, but editable in place:

- Each formula: the cells it fills (`B4:D4`), the spreadsheet form (`=B2-B3`), what it means in the table's words ("Mass of hydrated salt minus Mass of anhydrous salt"), and its status or error.
- Edit, with the same checks as typing in a cell (`ExcelFormulas.entering`): a formula that doesn't parse, or breaks something, isn't put in.
- Change how far it fills, set decimals, delete, add a new one for the selected cells.
- Raw `TBLFM` text in a disclosure for people who want it.

## 3. Graphs

### The blocks (Obsidian-compatible)

Researched 2026-10-14. Rather than invent a format, Indium reads and writes the formats of the two Obsidian plugins people already use, so a chart made in Indium draws in Obsidian with the plugin installed, and a chart made in Obsidian draws in Indium. Without the plugin, Obsidian shows the readable block as code.

**Charts from data: the Charts plugin's `chart` block** ([phibr0/obsidian-charts](https://github.com/phibr0/obsidian-charts)). YAML:

````markdown
| Trial | Temperature | Pressure |
| ----- | ----------- | -------- |
| 1     | 20          | 101.2    |
| 2     | 40          | 108.1    |

^results

```chart
type: line
id: results
layout: columns
select: [Pressure]
bestFit: true
xTitle: Temperature (°C)
yTitle: Pressure (kPa)
```
````

- Linking a table: a `^id` line under the table and `id:` in the block, exactly as the plugin does it. Indium already resolves `^id` lines this way for `![[Note#^block]]` embeds. `layout: columns` (the default) makes the first column the labels and each other column a series; `rows` the other way around. `select:` picks series. Inline data (`labels: [...]`, `series:` with `title`/`data`) works too.
- Keys Indium reads, all the plugin's own: `type` (`line`, `bar` first; `pie`/`doughnut` later), `labels`, `series`, `id`, `layout`, `select`, `bestFit`, `bestFitTitle`, `bestFitNumber`, `xTitle`, `yTitle`, `xMin`, `xMax`, `yMin`, `yMax`, `beginAtZero`, `legend`, `legendPosition`, `fill`, `stacked`, `width`, `spanGaps`. Anything else is kept and ignored.
- One deliberate difference: when every label is a number, Indium spaces the x axis by value (a real scatter/line plot), where the plugin spaces labels evenly. That's what lab data needs and it's still the same chart in both apps.
- Indium-only additions, ignored by the plugin: `type: scatter` (points, no line), `plot: [y = k x]` for curves over the data (flat `y = 3` and upright `x = 3` lines too), and `points: (1, 2), (2, 4)` for values typed straight in, no table needed. On a chart with word labels along x, x counts the labels (A is 1). Make Chart writes only plugin keys unless you choose one of these.
- Values with units (`2.008 g`) plot in Indium; the plugin can't read them. A table of plain numbers with the unit in the header is the portable form, and Make Chart suggests it.
- Caveat to check in Obsidian: Advanced Tables needs TBLFM lines directly under the table, and Obsidian wants the `^id` after a blank line. Whether Obsidian still ties the id to the table when a TBLFM comment sits between them is unverified; Indium will handle it either way.

**Function plots: the Desmos plugin's `desmos-graph` block** ([Nigecat/obsidian-desmos](https://github.com/Nigecat/obsidian-desmos), also read by Live Plots):

````markdown
```desmos-graph
left=-2; right=10; bottom=0; top=50
---
y=k x^2|blue
x=4|dashed
(3,9)|label:measured
```
````

- Settings before `---` as `key=value` (newlines or `;`): `left`, `right`, `top`, `bottom`, `width`, `height`, `grid`, `degreeMode`, `defaultColor`.
- One LaTeX equation per line, with `|` flags: colors, `solid`/`dashed`/`dotted`, `point`/`open`/`cross`, `hidden`, `label:…`, and restrictions like `x>0`.
- Indium draws these itself with its own evaluator, offline and with no Desmos. Supported: `y=f(x)`, `x=c`, `f(x)=…` definitions used by later lines, constants (`k=2`), and points. Implicit curves (`x^2+y^2=1`), sliders, and lists are kept and listed as unsupported on the graph.
- Note variables (frontmatter) work in Indium only; Desmos in Obsidian doesn't see them, so a constant written in the block (`k=2`) is the portable way.

### Drawing it

- **Swift Charts.** Built into macOS 26, no dependency, so the app stays small.
- Both blocks become a new `BlockDecoration.Content.chart` case, drawn the way display math is in `MarkdownStyler`: the chart replaces the source when the caret is away, and shows below the source while you edit it. Rendered to an image for the screen and as vectors for PDF export and Quick Look.
- **Units:** values read with `Quantity.parse`, so `2.008 g` plots as 2.008 and the axis title picks up `(g)`. Mixed or incompatible units in a column give a clear message on the chart instead of a wrong plot.
- **Function plots** go through `Evaluator` (and the LaTeX conversion in `MathAnswers`), sampled densely enough for curves, broken at gaps and asymptotes instead of drawing a vertical line across them.
- **Live:** editing the table redraws its charts. This needs a dependency step in styling (a table edit has to restyle chart blocks further down that read it), the main engineering risk in this section.
- On screen only: hovering a point shows its values.

### Graph section of the inspector

Type, data table, x column, y columns, plot equations (add, edit, remove, with errors shown as you type), fit and its results, axis titles and ranges (auto or set), legend, size. Each change rewrites the chart block as one undo step.

### Getting a chart in

`/chart` and `/graph` slash commands, "Make Chart" in the table toolbar's More menu and the inspector, and typing the block by hand.

## Order of work

1. **Research.** Done 2026-10-14: block formats follow the Obsidian Charts and Desmos plugins (above). Units and precision: option 1, nothing hidden.
2. **Done 2026-10-14. Inspector shell and variables.** The panel, toggle, caret-following, and the frontmatter writer. The smallest piece that proves the panel end to end.
3. **Table and formulas sections**, with selection sync both ways.
4. **Done 2026-10-14. Charts from tables.** Block parsing, Swift Charts drawing, PDF and Quick Look, live redraw, the Graph section.
5. **Done 2026-10-14 (linear fits; implicit curves later). Function plots and fits**, including plots over data.
6. **Finish.** Accessibility pass, docs (README, COMPATIBILITY.md, Formulas README), release notes.

Each step ships on its own branch and is checked in the running app.

## Testing

- Self-test cases in the `FormulaSelfTest` style (`-IndiumEvalCases`) for the frontmatter writer round trips, chart block parsing, sampling and fits.
- `DebugSnapshot` captures of the inspector in each mode and of charts in light, dark and PDF.
- Real lab notes (the six-column Results table) as copies, never the originals.

## Out of scope for now

3D plots, statistics beyond simple fits, charts that read from other notes, variables shared across notes, editing table values from the inspector.
