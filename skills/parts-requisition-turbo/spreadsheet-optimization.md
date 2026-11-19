# Spreadsheet optimization reference

## Range selection
- Inspect the sheet layout and headers before assuming columns.
- Handle empty sheets and header-only sheets.
- Prefer bounded ranges that include the needed columns and rows.
- Be cautious with `getLastRow()` when formulas or formatting extend beyond actual records.

## Bulk writes
- `setValues()` dimensions must match exactly.
- Preserve formulas when updating only data-owned cells.
- Never overwrite columns that contain formulas, manual notes, or protected data.
- Validate output in a test copy before live writes.

## Indexing
- Build a `Map` for keys such as part number, serial number, requisition ID, or transaction ID only after determining exact normalization/matching behavior.
- Avoid changing case, whitespace, leading zeros, or punctuation semantics unintentionally.
- Detect duplicate keys and preserve the current behavior (or ask if behavior is ambiguous).

## Cache discipline
For each cache, specify:
- key and version
- value shape
- TTL
- invalidation/update events
- whether stale data is tolerable
- fallback behavior
