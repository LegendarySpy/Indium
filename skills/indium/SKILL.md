---
name: indium
description: Write and edit notes for Indium, a Markdown editor for macOS. Use when creating or changing a note that will be read in Indium, especially one with columns, charts, graphs, equations, table formulas, note variables, callouts or embeds.
---

# Writing notes for Indium

Indium notes are plain Markdown files, compatible with Obsidian. Indium renders the syntax below as you'd expect from the app. Edit the file directly: an open note updates live. Anything Indium doesn't understand stays in the file and shows as text or code.

Put each special block on its own lines, with a blank line around it. Never wrap a whole note in a code fence.

## Everyday Markdown

- Headings, lists, `- [ ]` tasks, `> ` quotes, `---` dividers, code fences, pipe tables, links.
- `**bold**`, `*italic*`, `~~strike~~`, `==highlight==`, `` `code` ``.
- `[[Note]]`, `[[Note|shown text]]`, `[[Note#Heading]]`. `#tags`. `%% hidden comment %%`. Footnotes: `[^1]` and `[^1]: text`.
- Callouts: `> [!note] Title`, then more `> ` lines. Types include note, tip, info, warning. `[!tip]-` starts folded, `[!tip]+` open. Top level only.
- Embed a note on its own line: `![[Note]]`, `![[Note#Heading]]`.
- Image on its own line: `![[photo.png]]`, `![[photo.png|300]]` (width in points), `![Caption](photo.png)`, `![Caption|300](photo.png)`.
- `<!-- pagebreak -->` starts a new page in PDF export.

## Layout

Side-by-side columns, called boxes in the app. Two or three is typical. Widths are optional and written as ratios:

```markdown
<!-- columns 60/40 -->
## Left

Any blocks here, including tables and charts.
<!-- column -->
## Right

More blocks.
<!-- /columns -->
```

Use `<!-- columns -->` for equal widths. Markers go on their own lines, with no blank line needed around them. Don't nest columns.

To wrap the following text around a table or image, put this directly above it:

```markdown
<!-- float right -->
| A | B |
| --- | --- |
| 1 | 2 |
```

Use `float left` for the other side. Floats work only for one table or image, not for text.

## Math

LaTeX, `$inline$` or `$$display$$`. For a display equation, use `$$` on its own lines or around a single line.

- Escape percent: `$21.1\%$`. Outside math, write it plainly: 21.1%.
- Use `\text{...}` for words and units: `$3.0\ \text{g}$`.
- Fractions `\frac{a}{b}`, `\times`, `\cdot`, `\to`, `\sqrt{x}`, `\sum`, `\int`, Greek letters, `aligned`, `align`, `gather`, `pmatrix`, `bmatrix`, `cases`.
- Chemistry: mhchem's `\ce{}` and `\pu{}` don't render. Write `$\mathrm{H_2SO_4}$`, `$\mathrm{Fe^{3+}}$`, or H$_2$O in prose.
- Use math for sub- and superscripts, not Unicode characters like ₂ or ², `<sub>`, or `~x~`.
- A literal dollar sign in prose is `\$5`, so it isn't read as math.
- Math works in table cells. Avoid `|` there, since it ends the cell: use `\vert`.

## Note variables

Numbers in frontmatter, with optional units. Table formulas, charts and graphs can use them by name.

```markdown
---
mass: 2.008 g
yield: 85%
k: 0.5
---
```

Names start with a letter or `_` and contain letters, digits and `_`. Frontmatter must be the very first thing in the file. `icon: flask` sets the note's icon (an SF Symbol name). `created: 2026-10-26` or `date:` sets its date for sorting.

## Table formulas

Formulas go in `<!-- TBLFM: ... -->` lines directly under the table, with no blank line between. **Also write the computed results in the cells yourself.** Indium doesn't recalculate when a file is edited from outside; it marks the values out of date.

```markdown
| Item | Before | After | Change |
| --- | --- | --- | --- |
| Beaker | 35.1 g | 34.8 g | 0.3 g |
| Flask | 50.0 g | 48.5 g | 1.5 g |
| Total | | | 1.8 g |
<!-- TBLFM: @2$4..@3$4=($2-$3) -->
<!-- TBLFM: @4$4=sum(@2..@3);%.1f -->
```

- Row 1 is the header, and the `---` row isn't counted. `@3$2` is row 3, column 2. Ranges are `@2..@4` and `@2$2..@4$2`; `@>` and `$>` mean last, `@-1` and `$+1` are relative.
- A formula without a row applies to the whole column: `$4=($2-$3)`.
- Put every operation in its own parentheses: `((@4/@2)*100)`. Chain with `::`, or use another TBLFM line. Set decimals with `;%.1f`.
- Functions: `sum`, `mean` (not `AVERAGE`), `min`, `max`, `count`, `round`, `sqrt`, `abs`, `ln`, `log`, `sin`, `cos`, `tan`, and `^`. Variables by name: `(@4/water_molar_mass)`. Cells may hold units and `%`.
- Not supported: `IF`, comparisons, text, dates.
- Obsidian's Advanced Tables reads `sum`, `mean`, numbers and arithmetic. Keep the other functions and variables on their own TBLFM line.

## Charts

A fenced `chart` block. Types: `bar`, `line`, `scatter`, `pie`, `doughnut`.

Values written in the block:

````markdown
```chart
type: bar
title: Results
labels: [A, B, C]
series:
  - title: Group 1
    data: [3, 5, 2]
  - title: Group 2
    data: [4, 1, 6]
```
````

Points, with curves and a line of best fit:

````markdown
```chart
type: scatter
xTitle: Time (s)
yTitle: Distance (m)
points: (1, 2.1), (2, 3.9), (3, 6.2), (4, 7.8)
pointsTitle: Trial 1
bestFit: true
plot: [y = 2x, y = 3, x = 2]
```
````

From a table in the same note. Name the table with a `^name` line under it, after a blank line:

````markdown
| Time | Speed | Distance |
| --- | --- | --- |
| 1 | 2 | 3 |
| 2 | 4 | 5 |

^run

```chart
type: line
id: run
select: [Speed]
```
````

Each column after the first is a series, and the first column supplies the labels. `layout: rows` makes each row a series instead. Every row is charted, so a Total or Mean row shows as a bar: chart a table without one. Cells with `%` chart as fractions (36% draws as 0.36), so for a percent axis use plain numbers and put the `%` in the header.

Other keys: `style` (`mono`, `hatched`, `dotted`; default soft colors), `xMin`, `xMax`, `yMin`, `yMax`, `beginAtZero`, `legend`, `stacked`, `spanGaps`, `width` (`80%` or `400px`), `bestFitTitle`, `bestFitNumber`. A pie shows the first series. `plot` curves can use note variables: `plot: y = k x^2`.

Curves must start with `y =` or `x =`. A chart lists what it can't draw under itself. Radar, polar area and sankey charts aren't drawn, nor are tables in other notes.

`scatter`, `points`, `plot`, `style` and values with units are Indium only. The rest also draws in Obsidian's Charts plugin.

## Graphs

A fenced `desmos-graph` block for functions, drawn offline. One LaTeX equation per line, with optional settings before a `---` line:

````markdown
```desmos-graph
left=-10; right=10; bottom=-10; top=10
---
k=2
f(x)=k x^2
y=f(x)|blue
y=\sin(x)|red|dashed
x=3|dotted
(3,4)|label:Peak|open
y=x+1|x>0
```
````

- Settings: `left`, `right`, `top`, `bottom`, `width`, `height`, `grid`, `degreeMode`, `defaultColor`.
- After `|`: a color name or `#42ddf5`, `dashed`, `dotted`, `point`, `open`, `cross`, `hidden`, `label:text`, and restrictions like `x>0`.
- Note variables work by name in Indium. For Obsidian, define them in the graph (`k=2`).
- Not drawn: implicit curves (`x^2+y^2=1`), inequalities, derivatives, lists, sliders.

## Check your work

- Every `$` that opens math closes, with no space just inside it.
- Every `<!-- columns -->` has a matching `<!-- /columns -->`.
- Table results match their formulas, and TBLFM lines touch the table.
- Chart `id:` values match a `^name` line in the same note, and `select:` names match column headers exactly.
