# Formulas

The arithmetic behind quick answers (`1 + 2 =` → ghost `3`) and spreadsheet formulas in
Markdown tables. You type `=B2-B3` in a cell; the note stores an Advanced Tables `TBLFM`
comment under the table. Pure Foundation, no UI. Tables are found with the editor's
`MarkdownScanner`.

| File | What it is |
| --- | --- |
| `Evaluator.swift` | Parser and evaluator: `Quantity` (value, unit, precision), `FormulaUnit`, `FormulaPrecision`, `FormulaError` |
| `Variables.swift` | `NoteVariables`: numbers from the note's frontmatter |
| `TableFormulas.swift` | The TBLFM engine: parse formula lines, evaluate against a grid, Markdown helpers |
| `ExcelFormulas.swift` | Spreadsheet syntax (`=SUM(B2:B5)`) to and from TBLFM, and changing a table's formula lines cell by cell |
| `TableShapes.swift` | Keeping references on the same rows and columns when the table editor inserts or deletes some |
| `FormulaSelfTest.swift` | DEBUG regression runners (`-IndiumEvalCases`) |
| `../Editor/MathAnswers.swift` | Quick answers: LaTeX to plain syntax, then the evaluator |

## API

```swift
// Expressions
Evaluator.evaluate(_ source: String, options: .quickAnswer | .tableFormula, environment:) -> Result<Quantity, FormulaError>
Evaluator.parse(_:options:) -> Result<FormulaNode, FormulaError>      // then Evaluator.evaluate(node, environment:)
struct Quantity { value: Double; unit: FormulaUnit?; precision: FormulaPrecision
                  func formatted(decimals: Int? = nil) -> String     // "1.293 g"
                  func numberText(decimals: Int? = nil) -> String    // "1.293"
                  static func parse(_ cellText: String) -> Quantity?  // "2.008 g", "64.4%", "**3**" }
struct FormulaPrecision { isExact; decimals; significantFigures; style: .decimals | .significantFigures }
struct FormulaError { kind: .parse | .unknownVariable | .unknownFunction | .divisionByZero | .incompatibleUnits | .notReal
                            | .badReference | .notNumeric | .blank | .rangeMisuse | .cycle | .unsupported
                      message: String   // for people
                      position: Int?    // character offset, for parse errors }

// Variables
NoteVariables.parse(noteText:) -> NoteVariables    // .values: [String: Quantity]

// Quick answers
MathAnswer.suggest(lineBeforeCaret:inMath:variables:) -> MathAnswer.Result?   // insertion + display

// Tables
TableFormulas.evaluate(grid: [[String]], formulaLines: [String], variables:) -> Outcome
TableFormulas.apply(tableMarkdown:formulaLines:variables:) -> (markdown: String, outcome: Outcome)
TableFormulas.apply(toNote:) -> (text: String, outcomes: [Outcome])           // every scanner .table block with TBLFM lines
TableFormulas.trailingFormulaRange(in: NSString, tableRange: NSRange) -> NSRange?
TableFormulas.targets(grid:formulaLines:) -> [Cell: Int]                       // computed cells → index into parse(formulaLines:)
TableFormulas.parse(formulaLines:) -> [ParsedFormula]                          // for UI: each formula, verbatim text + result
TableFormulas.formulaText(ofLine:) / isFormulaLine(_:) / cells(ofRow:)
TableFormulas.formulaLine(_ formulas: [String]) -> String                  // "<!-- TBLFM: a::b -->"
TableFormulas.adjust(_ formulaLines:, for: .insertRows(at:count:) | .deleteRows | .insertColumns | .deleteColumns) -> [String]
struct Outcome { grid; formulas; issues: [Issue]; changed: [Cell]; blanks: [Cell]; succeeded: Bool }
struct Issue { formula: String; cell: Cell?; error: FormulaError }             // Cell: TBLFM numbering, row 1 = header

// Spreadsheet syntax (same Cell numbering: B4 is row 4, column 2)
ExcelFormulas.tblfm("=B2-B3", at: cell, fill: .cell | .row(through:) | .column(through:), variables:) -> Result<String, FormulaError>
ExcelFormulas.formula(at: cell, grid:, formulaLines:) -> String?          // "=C2-C3": what the cell shows while edited
ExcelFormulas.entering("=B2-B3", in: cell, grid:, formulaLines:, variables:) -> Result<[String], FormulaError>   // new formula lines
ExcelFormulas.filling(from: cell, down:, through:, grid:, formulaLines:, variables:) -> Result<[String], FormulaError>
ExcelFormulas.removing(from: cell, to: cell, in: formulaLines, grid:) -> [String]   // a value typed or cleared over computed cells
ExcelFormulas.message(FormulaError) -> String                              // "#DIV/0! Division by zero"
ExcelFormulas.name(cell) / columnName(_:)                                  // "B4", "AA"
```

`grid` is the header row followed by the body rows, without the `---` delimiter row.

**For the table UI.** Treat a table's TBLFM lines as part of the table block: they move,
copy and delete with it. `trailingFormulaRange` gives their range: the lines directly below
the table, with no blank line between, as Advanced Tables reads them. The block's range from
`MarkdownScanner` doesn't include these lines.
`apply(tableMarkdown:…)` rewrites only rows that changed, as `| a | b |`. Reformatting the
columns is up to the UI. Formula lines are never rewritten.

## In the editor (`../Editor/TableFormulaUI.swift`, `TableEditor.swift`)

- **Typing a formula.** In the table editor, type `=` in a cell and a formula, then Return
  or Tab: the cell shows the result. Clicking a computed cell shows its formula again, as
  the formula would read in that cell (`=C2-C3` in C4 of a row formula); leaving shows
  the value. The toolbar's **Formula** button (and Add Formula in a cell's menu) starts
  one with `=`. While a formula is typed, nothing is written to the note: it goes in
  with its results as one undo step, "Formula", when the cell is left. Escape (or Undo)
  puts the cell back as it was.
- **Naming cells.** Columns are letters, A being the first column (the label column
  too), and rows are numbers with the header row as 1, so B4 is TBLFM's `@4$2`. While a
  formula is typed, letters and numbers sit along the grid's top and left edges, the
  cells the formula names are outlined, and clicking another cell right after `=`, an
  operator, `(`, `,` or `:` puts its name in (a drag, a range like `B2:B5`; another click
  replaces it). Anywhere else, a click on another cell finishes the formula, as in a
  spreadsheet. The table view refuses first responder meanwhile, so the click can't
  take the keys from the cell.
- **The hint under the cell** shows the value as it would be ("B4 = 1.293 g") or what's
  wrong, in a spreadsheet's words ("#DIV/0! Division by zero", "#VALUE! B3 isn't a
  number (“two”)", "#NAME? Unknown name “mass”", "Circular reference: B5 → B5").
  A formula that doesn't parse, or gives a problem the table didn't have before, isn't
  put in: Return beeps, the hint turns red, and the cell stays open. The table is never
  left half-calculated by a formula typed here.
- **One cell, or filled.** A formula typed in a cell fills that cell only: `@4$2=(@2$2-@3$2)`.
  Fill Formula Right and Fill Formula Down (toolbar's More menu, or a cell's menu) copy
  the focused cell's formula to the end of its row or column, or across the selected
  cells, as a spreadsheet copies it: references move with each cell unless fixed with `$`
  (`$B$2`). A row fill is stored as one row formula:
  `@4$2..@4$>=(@2-@3)`. Formulas that only filled cells the new one fills are dropped.
- **Editing one cell of a filled formula** changes that cell only, as a spreadsheet
  does: a formula for just that cell is added after the others, where it wins. Typing
  the formula the cell already shows changes nothing, so existing lines keep their
  exact text (`@I`, `@>`, relative references and all) until you change them.
- **Values replace formulas.** A value typed, pasted or cleared over computed cells
  takes their formula away there; a formula that filled more keeps its other cells,
  split into smaller areas (`@4$2=(@2-@3)::@4$4..@4$>=(@2-@3)`).
- **One block.** `MarkdownScanner` gives the TBLFM lines right under a table their own
  `.tableFormulas` block, so they sit in the table's layout group: block drag, Wrap Text and
  Delete Table move or delete them with it. The editor draws them as a dimmed caption,
  "ƒ 2 formulas", or the first problem in red ("D3 (“Paper”, Total): #VALUE! B3 isn't a
  number (“two”)"). With the caret on them they show as source. PDF export, Quick Look
  and floating tables hide them.
- **Computed cells show it.** Each cell a formula fills (`TableFormulas.targets`) gets a
  faint tint and a small ƒ on screen, amber when its formula has a problem or its value is
  out of date. Hovering one shows its formula and what it means in the table's words
  ("=B2-B3", "Mass of hydrated salt − Mass of anhydrous salt"). Clicking the caption lists
  every formula ("B4:D4, Mass of water: =B2-B3"), each with Edit (it opens the formula's
  first cell), plus Show Source. Paper, PDFs and Quick Look show none of this.
- **Recalculation** runs in the table editor only: after a formula goes in, a change of
  shape, a paste, or clearing cells at once, and when you leave a cell you typed a value
  in. The results go into the same undo step as the edit, so one Undo restores the inputs
  and the outputs. On any issue nothing changes (the engine is atomic) and the caption
  shows why. Only real `.table` blocks are touched, never fenced code. Typing in the
  Markdown source doesn't recalculate.
- **Frontmatter variables are inputs too.** A run of edits inside the frontmatter is one
  edit session: its first edit registers a single undo step that restores the frontmatter as
  it started, and the edits after it record nothing. When the session ends (the caret leaves
  the frontmatter, Save, or the note is switched or closed; autosave writes the text as it is and leaves the session open), tables whose formulas name a
  variable whose value changed are recalculated, and that same undo step grows to restore
  them too. An edit outside the frontmatter ends the session without recalculating (the
  caption then says "values out of date"). Never on every keystroke.
- **Recalculate.** A caption that says "values out of date" (a note saved elsewhere, an edit
  in the Markdown source) offers Recalculate: clicking the word recalculates that table
  as one undo step, "Recalculate Formulas". With a problem nothing changes and the caption
  shows it instead.
- **References follow rows and columns** inserted or deleted *through the table editor*
  (toolbar, cell menu, edge strips). The editor reports the operation and its index, and
  absolute references (`@4`, `$2`) shift like a spreadsheet's, so B4 becomes B5 when a row
  goes in above it. A formula whose destination was deleted is removed. A reference to a
  deleted row or column becomes `#REF`, which doesn't parse, so the table isn't
  recalculated until that formula is fixed or removed in the source.
  Ranges shrink with their rows. Relative references and `<`, `>`, `I` are left alone.
  A line holding any formula the engine doesn't parse (unsupported or mistyped) is kept
  byte for byte, and its references are **not** adjusted.
- **Positional elsewhere.** Rows or columns added or removed by editing the Markdown
  source, in another app, or by Advanced Tables don't move references: they keep their
  numbers.

## Spreadsheet syntax (`ExcelFormulas.swift`)

| Typed in a cell | Stored (TBLFM) |
| --- | --- |
| `=B2-B3` in B4 | `@4$2=(@2$2-@3$2)` |
| `=B4/B2*100` | `((@4$2/@2$2)*100)`: every operation gets its own parentheses |
| `=ROUND(B4/B2*100, 1)` | `((@4$2/@2$2)*100);%.1f` |
| `=ROUND(B4, 1)*2` | `(round(@4$2,1)*2)` (Indium only) |
| `=SUM(B2:B5)` | `sum(@2$2..@5$2)` |
| `=AVERAGE(B2:D2)` | `mean(@2$2..@2$4)` |
| `=MIN(…)` `MAX` `COUNT` | `min(…)` `max` `count` (Indium only) |
| `=SQRT(B2)` `ABS` `LN` `LOG10` / `LOG` `SIN` `COS` `TAN` | `sqrt(@2$2)` `abs` `ln` `log` … (Indium only) |
| `=POWER(B2, 2)`, `=B2^2` | `(@2$2^2)` (Indium only) |
| `=PI()` | `pi` |
| `=50%*B2` | `((50/100)*@2$2)`, shown as `=50/100*B2` |
| `=B4/water_molar_mass` | `(@4$2/water_molar_mass)` |
| `=B2-B3`, Fill Right from B4 | `@4$2..@4$>=(@2-@3)` |
| `=B4/$B$2`, Fill Right from B5 | `@5$2..@5$>=(@4/@2$2)`, shown in C5 as `=C4/$B2` |
| `=B2*C2`, Fill Down from D2 | `@2$4..@>$4=($2*$3)` |

- Function names and cell names aren't case-sensitive; they're shown in capitals.
  Precedence is the evaluator's, so `-B2^2` is −(B2²), unlike a spreadsheet's.
- A word shaped like a cell (`x1`) is a cell unless the note defines a variable by
  exactly that name. Write `$` (`$X$1`) to mean the cell anyway.
- `ROUND(x, n)` at the top with a whole `n` from 0 to 15 is the `;%.nf` directive, so
  Advanced Tables reads it. Anywhere else (nested, or a negative `n`) it's Indium's
  `round(x, n)`, which Advanced Tables can't parse.
- Not supported, with a message: `IF`, comparisons, text in quotes, `TRUE`/`FALSE`,
  `LOG` with a base, and functions Indium doesn't have (`#NAME? Unknown function FOO`).
- Shown back, a formula loses only its redundant parentheses (`((@4/@2)*100)` shows as
  `=B4/B2*100`), and `<`, `>`, `I` and relative references show as the cells they reach
  from that cell. Those only change in the file if you change the formula.
- `$` shows where a reference stays put as a filled formula fills more cells.

## Expression syntax (both features)

- Numbers: `2`, `2.008`, `.5`, `6.022e23`. `+ - * / ^` (also `× · ÷ −`), parentheses.
  Precedence is standard, and `^` is right-associative: `-2^2 = -4`, `2^3^2 = 512`, `2^-2 = 0.25`.
- Postfix `%` divides by 100 (`15% * 200 = 30`). It is never a unit.
- Functions: `sqrt sin cos tan log ln abs` (`sqrt 16` also works), `sum mean min max count`
  with comma arguments or ranges, and `round(x, n)`, half away from zero, to n decimal places
  (never more than a measured input had: `round(1.2, 3)` is 1.2). Constants: `pi`, `π`, `e`.
  Names of functions and constants aren't case-sensitive.
- Quick answers only: implicit multiplication (`2pi`, `2(3)`), but never next to a variable
  (`2 mass` is an error). Two numbers in a row (`1 2`) are an error.
- Units in quick answers come after a number, either as LaTeX `\text{ g}` in math (any text)
  or as a known unit word in prose (`2.008 g`, `65.38 g/mol`, `16 m^2`). The word list is in
  `Evaluator.unitWords`, which stops `3 x + 2` from becoming "5 x".

## Units

No conversion and no symbolic algebra. `g` and `kg` are different units.

- **+ and −**: both sides need the same unit, and the result keeps it (`2.008 g − 0.715 g = 1.293 g`).
  A plain number takes the other side's unit (`35.134 g − 34.794 = 0.340 g`). Different units
  give `incompatibleUnits`. `sum`, `mean`, `min` and `max` follow the same rule, and `count` has no unit.
- **× and ÷**: units made of simple symbols (`g`, `mol`, `g/mol`, `J/(mol·K)`, `m^2`) multiply,
  divide and cancel: `g/g` gives a plain number, `mol × g/mol` gives `g`, and `1/(3 g)` gives `g^-1`.
  Any other unit text (`g Zn`) is an opaque label. It survives × or ÷ by a plain number, and it
  cancels against itself. Any other operation with it is an error, never a plain number.
- **Powers**: a whole exponent raises the unit (`(2 m)^2 = 4 m^2`). `(4 m)^0.5` is an error, and so is `sqrt` of a unit with odd exponents.
  `sin cos tan log ln` of a value with a unit are errors. An exponent can't have a unit.
- Rendering is canonical, and **every result parses back**: `g·mol`, `g/mol`, `J/(mol·K)`, `g^-1`, `mol^-1·L^-1`.
  Units can't contain `| % ` or line breaks, and they start with a letter or `µ μ Ω ° Å`.

## Precision

These are chemistry-notebook significant-figure rules, applied step by step:

- A whole-number literal and the constants are **exact**. A literal with a point or exponent is
  **measured**: `2.008` has 3 decimal places and 4 figures, and `2.50` has 3 figures.
- After + and −, the result keeps the fewest decimal places of the measured inputs. After ×, ÷, `^`
  and functions, it keeps the fewest significant figures. The exponent of `^` doesn't count.
  `(2.008 − 0.715)/2.008 × 100 = 64.39`.
- The result is written in the style of its last step, as decimals or as figures. Scientific
  notation is used when the magnitude is at least 10⁹ or at most 10⁻⁶, or the value is at least 10¹⁵.
- Exact results show up to 6 decimals, with trailing zeros trimmed (`1/3 = 0.333333`).
- Rounding is half away from zero in decimal (`3.25 → 3.3`, `1.005 → 1.01`).
- Bounds: at most 17 figures and 15 decimals are shown. Non-finite literals and results are
  errors (`1e999`). Unit exponents are capped at 1000.
- In tables, `;%.Nf` fixes the decimal places (N ≤ 15).

## Note variables

```yaml
---
hydrated: 2.008 g
anhydrous: 0.715 g
water_molar_mass: 18.02 g/mol
---
```

- Only the YAML at the very top of the note counts: a first line of `---`, closed by `---` or `...`.
  Only the first 400 lines are read.
- Only top-level `name: value` lines count. Names match `[A-Za-z_][A-Za-z0-9_]*` and are
  **case-sensitive**. Other keys (`molar mass`, `molar-mass`, `ΔH`) are ignored. Names of
  functions and constants (`sum`, `pi`, `e`, …, in any case) are ignored.
- A value is a number, with an optional unit or `%`, and may be quoted (`"0.20"`). A trailing
  `# comment` is dropped. Text, dates, booleans, lists and nested maps are ignored without
  error. If a key appears twice, the last one wins.
- In quick answers, a candidate expression counts only if **every** name in it is a function,
  a constant or a defined variable. It also needs an operation, so `hydrated =` alone shows
  nothing. Prose like `I think that is =` stays quiet even if `is` and `that` are variables,
  because juxtaposed names are an error.

## Table formulas (TBLFM)

```
| Quantity               | CuSO₄·5H₂O | MgSO₄·7H₂O |
| ---------------------- | ---------- | ---------- |
| Mass of hydrated salt  | 2.008 g    | 1.502 g    |
| Mass of anhydrous salt | 0.715 g    | 0.733 g    |
| Mass of water          | 1.293 g    | 0.769 g    |
| Percent water          | 64.4       | 51.2       |
<!-- TBLFM: @4$2..@4$>=(@2-@3) -->
<!-- TBLFM: @5$2..@5$>=((@4/@2)*100);%.1f -->
```

The table editor writes these from spreadsheet formulas (see above). A row filled from
its first number column is `@R$2..@R$>=(…)`, never `@R=(…)`: upstream fills every column
with that, including the label column, so the formula fails (see below).

### Supported, matching upstream
- Wrapper: `<!-- TBLFM: … -->`, on the lines directly after the table. Several formulas on a
  line are chained with `::`. Several lines run top to bottom.
- Rows: `@1` is the header row, `@2` the first body row (the delimiter row isn't counted),
  `@<` the first row, `@>` the last row and `@I` the first body row. `@-1` and `@+2` are relative.
  Columns: `$1`, `$<`, `$>`, `$-1`, `$+1`. `@0` and `$0` mean the current row or column.
  A missing part means the destination cell's own row or column (`@2` means row 2 in this column).
- Destinations: `@r$c`, `@r` (**every column, label column included**, as upstream),
  `$c` (every row below the header), and ranges of absolute cells `@r1$c1..@r2$c2` (the end
  column defaults to the start column). Relative destinations are rejected.
- Sources: references, ranges `@2..@4`, `@2$3..@5`, `$2..$4` (inside functions), `sum`,
  `mean`, numeric literals, and `(a op b)` arithmetic. **Every operation needs its own
  parentheses**, as in upstream's grammar: `((@4/@2)*100)`. `@4=@2-@3` is a parse error that says so.
- `;%.Nf` display directive.

### Extensions
These evaluate in Indium only. Advanced Tables fails to parse the line that holds them.
- `min`, `max`, `count`, and comma arguments (`max(@2, @3)`). `sqrt sin cos tan log ln abs`, `round(x, n)` and `^`. Unary minus on any value.
- Note variables by name (`(@4/water_molar_mass)`). Keep formulas that use them on their own TBLFM line.
- Units and significant figures as above. Upstream ignores units and prints full binary precision.

### Deliberate deviations from upstream
1. **Blank inputs.** Upstream reads an empty cell as 0. Here a blank input leaves the
   destination blank. That isn't an error: the cell is listed in `Outcome.blanks`. A `sum` over
   a range skips blanks.
2. **Text inputs** give the error `notNumeric`. Upstream's Decimal parse throws on them.
3. **Atomic.** If any formula fails to parse, is unsupported, or fails for any cell, *no* cell
   changes, and every problem is reported. Upstream stops at the first error.
4. **Dependency order, like a spreadsheet.** A formula sees the final values of the cells it
   reads, whatever order the formulas are written in. When two formulas target the same cell,
   the later one wins. Cycles, including a cell that reads itself (`$2=($2*2)`), give the error
   `cycle` instead of compounding each time you run them. As a result, running the formulas
   twice changes nothing. (Upstream applies formulas in sequence, and its code runs chained
   formulas on one line right to left, contrary to its docs.)
5. A formula reads a computed cell through that cell's **formatted text**, the same text a
   later run would read. So results never depend on hidden precision.
6. Ranges are allowed only inside functions. Upstream lets `(range op cell)` produce lists.
7. Relative references count table rows only. Upstream's `@-1` from the first body row lands on
   the delimiter line. Here it lands on the header.
8. Bounds: an index above 100000 is a parse error. Out-of-table references and destinations
   are checked before any range is walked.

### Not supported
These are reported as `unsupported` or `parse`, and the line is always kept verbatim:
- `if(…)` and the comparison operators
- `;dt` and `;hm`, and times and durations (`10:30`, datetimes)
- A `;` used between formulas. The error points to `::`.

## Obsidian round-trip

- Results are ordinary cell text, so stock Obsidian (and GitHub, and any Markdown viewer)
  shows the stored values. The TBLFM comment is hidden in Obsidian's reading view and shown
  in source mode.
- Obsidian with Advanced Tables evaluates upstream-compatible lines itself. It ignores units
  and precision, so it would rewrite `1.293 g` as `1.293`. A line with Indium extensions
  (variables, `min`/`max`/`count`, math functions) fails to parse there.
- Obsidian doesn't evaluate Indium's frontmatter variables. They are plain properties there.

## Tests

`-IndiumEvalCases` takes comma-separated files. Each file names its kind on its first line.

```
Indium -ApplePersistenceIgnoreState YES -IndiumSnapshot /tmp/x.png \
  -IndiumEvalCases Tests/Formulas/quick_answers.tsv,Tests/Formulas/evaluator.tsv,Tests/Formulas/tblfm_cases.md,Tests/Formulas/excel_cases.tsv \
  [-IndiumEvalVerbose YES]
```

- `quick_answers.tsv`: the expected behaviour of quick answers. `# CHANGED:` lines mark
  deliberate fixes. It also covers variables and lines that must stay quiet.
- `evaluator.tsv`: precedence, precision, units, errors and bounds. Every success must parse back.
- `tblfm_cases.md`: whole notes in and out, including the example table above, upstream's doc
  examples, atomicity, unsupported formulas left intact, cycles, bounds, and fenced code left untouched.
  A case's `--- edit` section types in the first table's cells first, as the table editor
  does (`B4 =B2-B3`, `C4 5`, `fill-right B4`), and `--- show` checks the formula a cell shows.
- `excel_cases.tsv`: spreadsheet syntax to TBLFM and back (every success must show again as
  typed), filled formulas, refusals, and the messages the table editor shows.

The runners need only Foundation. For a fast loop without the app:

```
swiftc -D DEBUG Sources/Formulas/*.swift Sources/Editor/MathAnswers.swift Sources/Editor/MarkdownScanner.swift main.swift
```

Here `main.swift` calls `FormulaSelfTest.run(paths:)`.
