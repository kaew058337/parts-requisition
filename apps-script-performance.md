# Apps Script performance reference

Use this checklist while inspecting the project. It is guidance, not a mandate to rewrite code.

## Common service-call hotspots
- `getRange(...).getValue()` repeated in loops
- `setValue()` repeated in loops
- `getDataRange().getValues()` called repeatedly by multiple helpers during one request
- `SpreadsheetApp.openById()` or `getSheetByName()` repeated unnecessarily
- Repeated reads of the same lookup/master table
- Formula recalculation or formatting applied to large ranges unnecessarily

## Safe batch pattern
1. Read the required contiguous block once with `getValues()`.
2. Convert rows to an in-memory representation.
3. Perform pure calculations in JavaScript.
4. Write one rectangular result block with `setValues()` when safe.
5. Preserve existing formulas, validations, formatting, and columns not owned by the operation.

## Timing
Use `console.time()` / `console.timeEnd()` or a small helper around meaningful sections, if supported by the current Apps Script runtime. Log operation names and durations, not personal or sensitive row contents. Remove or gate verbose instrumentation before production.

## Chunking
If an operation exceeds safe memory/runtime limits, use chunks. Confirm whether partial completion is acceptable; for transactions requiring all-or-nothing behavior, do not introduce partial writes without a recovery strategy.
