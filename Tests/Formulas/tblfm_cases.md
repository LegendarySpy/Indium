# kind: tables
Table formula cases for Sources/Formulas/TableFormulas.swift. Each case is a whole note in
(frontmatter, table, TBLFM lines), the whole note out, and the issues it must report.
Run: Indium -IndiumEvalCases Tests/Formulas/tblfm_cases.md -IndiumEvalVerbose YES -IndiumSnapshot /tmp/x.png

=== owner's Results table: rows from rows, explicit column ranges keep the label column out
---
course: CHEM 101
water_molar_mass: 18.02 g/mol
---

## Results

| Quantity               | CuSO₄·5H₂O | MgSO₄·7H₂O | Unknown |
| ---------------------- | ---------- | ---------- | ------- |
| Mass of hydrated salt  | 2.008 g    | 1.502 g    | 1.751 g |
| Mass of anhydrous salt | 0.715 g    | 0.733 g    | 1.120 g |
| Mass of water          |            |            |         |
| Percent water          |            |            |         |
| Moles of water         |            |            |         |
<!-- TBLFM: @4$2..@4$>=(@2-@3) -->
<!-- TBLFM: @5$2..@5$>=((@4/@2)*100);%.1f -->
<!-- TBLFM: @6$2..@6$>=(@4/water_molar_mass) -->

Notes go on here.
--- expect
---
course: CHEM 101
water_molar_mass: 18.02 g/mol
---

## Results

| Quantity               | CuSO₄·5H₂O | MgSO₄·7H₂O | Unknown |
| ---------------------- | ---------- | ---------- | ------- |
| Mass of hydrated salt  | 2.008 g    | 1.502 g    | 1.751 g |
| Mass of anhydrous salt | 0.715 g    | 0.733 g    | 1.120 g |
| Mass of water | 1.293 g | 0.769 g | 0.631 g |
| Percent water | 64.4 | 51.2 | 36.0 |
| Moles of water | 0.07175 mol | 0.0427 mol | 0.0350 mol |
<!-- TBLFM: @4$2..@4$>=(@2-@3) -->
<!-- TBLFM: @5$2..@5$>=((@4/@2)*100);%.1f -->
<!-- TBLFM: @6$2..@6$>=(@4/water_molar_mass) -->

Notes go on here.

=== running the Results formulas again changes nothing (idempotent)
| Quantity | A |
| --- | --- |
| Mass of hydrated salt | 2.008 g |
| Mass of anhydrous salt | 0.715 g |
| Mass of water | 1.293 g |
<!-- TBLFM: @4$2..@4$>=(@2-@3) -->
--- expect
| Quantity | A |
| --- | --- |
| Mass of hydrated salt | 2.008 g |
| Mass of anhydrous salt | 0.715 g |
| Mass of water | 1.293 g |
<!-- TBLFM: @4$2..@4$>=(@2-@3) -->

=== a whole-row destination includes the label column, as upstream, so it is refused and nothing changes
| Quantity | A | B |
| --- | --- | --- |
| Mass of hydrated salt | 2.008 g | 1.502 g |
| Mass of anhydrous salt | 0.715 g | 0.733 g |
| Mass of water | | |
<!-- TBLFM: @4=(@2-@3) -->
--- expect
| Quantity | A | B |
| --- | --- | --- |
| Mass of hydrated salt | 2.008 g | 1.502 g |
| Mass of anhydrous salt | 0.715 g | 0.733 g |
| Mass of water | | |
<!-- TBLFM: @4=(@2-@3) -->
--- issues
@4$1 [notNumeric] @2$1 isn't a number (“Mass of hydrated salt”)

=== arithmetic without parentheses is refused (Advanced Tables grammar), nothing changes
| Quantity | A |
| --- | --- |
| Hydrated | 2.008 g |
| Anhydrous | 0.715 g |
| Water | |
<!-- TBLFM: @4$2=@2-@3 -->
--- expect
| Quantity | A |
| --- | --- |
| Hydrated | 2.008 g |
| Anhydrous | 0.715 g |
| Water | |
<!-- TBLFM: @4$2=@2-@3 -->
--- issues
[parse] Put each operation in its own parentheses

=== upstream example: total with sum(@I..@-1)
| Item              | Grams |
| ----------------- | ----- |
| Whole Wheat Flour | 110   |
| Bread Flour       | 748   |
| Warm Water        | 691   |
| Salt              | 18    |
| Starter           | 40    |
| **Total Grams**   |       |
<!-- TBLFM: @>$2=sum(@I..@-1) -->
--- expect
| Item              | Grams |
| ----------------- | ----- |
| Whole Wheat Flour | 110   |
| Bread Flour       | 748   |
| Warm Water        | 691   |
| Salt              | 18    |
| Starter           | 40    |
| **Total Grams** | 1607 |
<!-- TBLFM: @>$2=sum(@I..@-1) -->

=== upstream example: Fibonacci with relative rows down the last column
| Start | Fibonacci |
|-------|-----------|
|     1 |         1 |
|     1 |         1 |
|       |           |
|       |           |
|       |           |
|       |           |
<!-- TBLFM: @4$>..@>$>=(@-1+@-2) -->
--- expect
| Start | Fibonacci |
|-------|-----------|
|     1 |         1 |
|     1 |         1 |
|  | 2 |
|  | 3 |
|  | 5 |
|  | 8 |
<!-- TBLFM: @4$>..@>$>=(@-1+@-2) -->

=== upstream example: row destination, cell minus each column of a row
| One | Two | Three |
|-----|-----|-------|
|   1 |   2 |     3 |
|   4 |   5 |     6 |
|     |     |       |
<!-- TBLFM: @>=(@2$3-@3) -->
--- expect
| One | Two | Three |
|-----|-----|-------|
|   1 |   2 |     3 |
|   4 |   5 |     6 |
| -1 | -2 | -3 |
<!-- TBLFM: @>=(@2$3-@3) -->

=== upstream example: ;%.2f format directive
| A   | B   | C   | D   |
| --- | --- | --- | --- |
| 1   | 2   | 5   | 6   |
| 3   | 4   | 7   | 8   |
|     |     |     |     |
<!-- TBLFM: @>=(@I/@3$4);%.2f -->
--- expect
| A   | B   | C   | D   |
| --- | --- | --- | --- |
| 1   | 2   | 5   | 6   |
| 3   | 4   | 7   | 8   |
| 0.13 | 0.25 | 0.63 | 0.75 |
<!-- TBLFM: @>=(@I/@3$4);%.2f -->

=== column destination skips the header; :: chains; later formulas can feed earlier ones
| x | double | plus one |
| --- | --- | --- |
| 1.5 | | |
| 2.25 | | |
<!-- TBLFM: $3=($2+1)::$2=($1*2) -->
--- expect
| x | double | plus one |
| --- | --- | --- |
| 1.5 | 3.0 | 4.0 |
| 2.25 | 4.50 | 5.50 |
<!-- TBLFM: $3=($2+1)::$2=($1*2) -->

=== sum, mean, min, max and count over a range with a blank cell
| Trial | Mass |
| --- | --- |
| 1 | 2.01 g |
| 2 | |
| 3 | 1.99 g |
| 4 | 2.03 g |
| Sum | |
| Mean | |
| Min | |
| Max | |
| Count | |
<!-- TBLFM: @6$2=sum(@2..@5)::@7$2=mean(@2..@5)::@8$2=min(@2..@5)::@9$2=max(@2..@5)::@10$2=count(@2..@5) -->
--- expect
| Trial | Mass |
| --- | --- |
| 1 | 2.01 g |
| 2 | |
| 3 | 1.99 g |
| 4 | 2.03 g |
| Sum | 6.03 g |
| Mean | 2.01 g |
| Min | 1.99 g |
| Max | 2.03 g |
| Count | 3 |
<!-- TBLFM: @6$2=sum(@2..@5)::@7$2=mean(@2..@5)::@8$2=min(@2..@5)::@9$2=max(@2..@5)::@10$2=count(@2..@5) -->

=== a blank input leaves the result blank (not 0), with no issue
| Quantity | A | B |
| --- | --- | --- |
| Hydrated | 2.008 g | |
| Anhydrous | 0.715 g | 0.733 g |
| Water | | 9.99 g |
<!-- TBLFM: @4$2..@4$>=(@2-@3) -->
--- expect
| Quantity | A | B |
| --- | --- | --- |
| Hydrated | 2.008 g | |
| Anhydrous | 0.715 g | 0.733 g |
| Water | 1.293 g |  |
<!-- TBLFM: @4$2..@4$>=(@2-@3) -->

=== mixed units in a subtraction: error, nothing changes
| Quantity | A | B |
| --- | --- | --- |
| Hydrated | 2.008 g | 1.502 g |
| Anhydrous | 0.715 g | 0.0040 mol |
| Water | | |
<!-- TBLFM: @4$2..@4$>=(@2-@3) -->
--- expect
| Quantity | A | B |
| --- | --- | --- |
| Hydrated | 2.008 g | 1.502 g |
| Anhydrous | 0.715 g | 0.0040 mol |
| Water | | |
<!-- TBLFM: @4$2..@4$>=(@2-@3) -->
--- issues
@4$3 [incompatibleUnits] Can't subtract mol from g

=== invalid formula cannot partially overwrite a table
| a | b |
| --- | --- |
| 1 | |
| 2 | |
<!-- TBLFM: @2$2=($1*10) -->
<!-- TBLFM: @3$2=($1/0) -->
--- expect
| a | b |
| --- | --- |
| 1 | |
| 2 | |
<!-- TBLFM: @2$2=($1*10) -->
<!-- TBLFM: @3$2=($1/0) -->
--- issues
@3$2 [divisionByZero] Division by zero

=== unsupported formula remains intact (if(), ;dt), and blocks the rest
| a | b |
| --- | --- |
| 1 | |
| 5 | |
<!-- TBLFM: $2=if($1>3, $1, 3)::@2$2=($1+1) -->
<!-- TBLFM: @3$2=($1+1);dt -->
--- expect
| a | b |
| --- | --- |
| 1 | |
| 5 | |
<!-- TBLFM: $2=if($1>3, $1, 3)::@2$2=($1+1) -->
<!-- TBLFM: @3$2=($1+1);dt -->
--- issues
[unsupported] if() isn't supported yet
[unsupported] The ;dt date/time format isn't supported yet

=== “;” between formulas gets a pointer to “::”
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2=($1+1); @2$1=1 -->
--- expect
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2=($1+1); @2$1=1 -->
--- issues
Separate formulas with “::”

=== cycle: formulas that depend on each other are reported, nothing changes
| a | b |
| --- | --- |
| 1 | 2 |
| 3 | 4 |
<!-- TBLFM: @2$2=(@3$2+1)::@3$2=(@2$2+1) -->
--- expect
| a | b |
| --- | --- |
| 1 | 2 |
| 3 | 4 |
<!-- TBLFM: @2$2=(@3$2+1)::@3$2=(@2$2+1) -->
--- issues
@2$2 [cycle] Formulas depend on themselves: @2$2 → @3$2 → @2$2
@3$2 [cycle] Formulas depend on themselves

=== a cell that refers to itself is a cycle
| a | b |
| --- | --- |
| 1 | 2 |
<!-- TBLFM: $2=($2*2) -->
--- expect
| a | b |
| --- | --- |
| 1 | 2 |
<!-- TBLFM: $2=($2*2) -->
--- issues
@2$2 [cycle]

=== huge destination range is refused before it is walked
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2..@99999$2=(1+1) -->
--- expect
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2..@99999$2=(1+1) -->
--- issues
[badReference] Row 99999 is outside the table

=== absurd and overflowing references are refused
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2..@999999999$2=(1+1) -->
<!-- TBLFM: @2$2=@-99999999999999999999 -->
<!-- TBLFM: @2$2=(@-99999+1) -->
<!-- TBLFM: @2$2=($1*2);%.99999999999999999999f -->
--- expect
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2..@999999999$2=(1+1) -->
<!-- TBLFM: @2$2=@-99999999999999999999 -->
<!-- TBLFM: @2$2=(@-99999+1) -->
<!-- TBLFM: @2$2=($1*2);%.99999999999999999999f -->
--- issues
[parse] “@2$2..@999999999$2” isn't a destination
[parse] “@-99999999999999999999” is far beyond any table
asks for too many decimal places (15 at most)

=== a relative reference outside the table, evaluated per cell
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2=(@-99999+1) -->
--- expect
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2=(@-99999+1) -->
--- issues
@2$2 [badReference] Row -99997 is outside the table

=== a destination outside the table is refused
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @9$2=1 -->
--- expect
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @9$2=1 -->
--- issues
[badReference] Row 9 is outside the table

=== a relative destination is refused
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @+1$2=1 -->
--- expect
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @+1$2=1 -->
--- issues
[badReference] A destination can't be relative

=== unknown variable
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2=($1*factor) -->
--- expect
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2=($1*factor) -->
--- issues
@2$2 [unknownVariable] Unknown name “factor”

=== a table inside a code fence is never touched
```
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2=($1+1) -->
```
--- expect
```
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2=($1+1) -->
```

=== two tables, each with its own formulas; a blank line detaches a comment
| a | b |
| --- | --- |
| 1 | |
<!-- TBLFM: @2$2=($1+1) -->

| c | d |
| --- | --- |
| 5 | |

<!-- TBLFM: @2$2=($1+1) -->
--- expect
| a | b |
| --- | --- |
| 1 | 2 |
<!-- TBLFM: @2$2=($1+1) -->

| c | d |
| --- | --- |
| 5 | |

<!-- TBLFM: @2$2=($1+1) -->

=== percent and composite units read back from cells
| q | v | out |
| --- | --- | --- |
| yield | 85.0% | |
| rate | 2.0 mol/L | |
| inverse | 4.0 g^-1 | |
<!-- TBLFM: @2$3=(@2$2*200)::@3$3=(@3$2*3)::@4$3=(@4$2*2) -->
--- expect
| q | v | out |
| --- | --- | --- |
| yield | 85.0% | 170 |
| rate | 2.0 mol/L | 6.0 mol/L |
| inverse | 4.0 g^-1 | 8.0 g^-1 |
<!-- TBLFM: @2$3=(@2$2*200)::@3$3=(@3$2*3)::@4$3=(@4$2*2) -->
