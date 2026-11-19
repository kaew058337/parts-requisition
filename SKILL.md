---
name: parts-requisition-turbo
description: Analyze, optimize, and benchmark a Google Apps Script + Google Sheets parts requisition/inventory application. Use when improving calculation speed, stock calculations, spreadsheet reads/writes, caching, lookup performance, web-app latency, or Apps Script reliability. Preserve existing business rules and data integrity.
---

# Parts Requisition Turbo

## Mission
Improve the performance, responsiveness, and scalability of the Parts Requisition application without changing its established business behavior, data model, permissions, or inventory results unless the user explicitly authorizes a functional change.

## Project context
- Repository: `https://github.com/kaew058337/parts-requisition`
- Treat the current repository contents as the source of truth. Do not assume filenames, sheet names, column indexes, or formulas without inspecting them.
- Likely environment: Google Apps Script, Google Sheets, and an Apps Script Web App. Verify this in the code before making assumptions.
- Inventory operations may include requisitions, issue/return, borrowing, stock counts, and kit-related workflows. Identify which features exist in the current checkout.

## Required workflow
1. **Inspect first**
   - Read README, manifest, server code, HTML/client code, and relevant configuration.
   - Map the request to functions, data sheets/ranges, and UI calls.
   - Trace the current calculation and identify the authoritative source of truth.
2. **Establish a baseline**
   - Record existing behavior and results for representative cases.
   - If timing instrumentation is possible, measure the target operation before changing it.
   - Distinguish UI rendering time, `google.script.run` latency, Apps Script execution time, and spreadsheet API time.
3. **Find the bottleneck**
   - Search for repeated `getRange`, `getValue`, `getValues`, `setValue`, `setValues`, `getDataRange`, spreadsheet opens, nested loops, repeated lookups, and repeated full-stock rebuilds.
   - Check for unnecessary client/server round trips, large payloads, repeated sorting/filtering, and expensive formatting.
   - Avoid speculative optimization: explain the evidence for the target.
4. **Propose a minimal change**
   - State the bottleneck, proposed change, expected benefit, risk, and validation plan.
   - Prefer one isolated optimization at a time.
   - Do not refactor unrelated code or alter UI/business logic merely for style.
5. **Implement safely**
   - Batch spreadsheet reads/writes.
   - Use in-memory indexes (`Map`/plain objects) for repeated key lookups when appropriate.
   - Compute derived values once per request.
   - Narrow ranges to required rows/columns.
   - Avoid spreadsheet service calls inside loops.
   - Reuse data already loaded in the current execution.
   - Cache only data that is safe to cache and define invalidation on every mutation that can affect it.
   - Keep client/server calls consolidated where possible, while preserving error handling and user feedback.
6. **Validate**
   - Compare before/after outputs for the same fixtures or sample records.
   - Test empty data, missing fields, duplicate part numbers, invalid quantities, decimal quantities if supported, large datasets, and concurrent edits where relevant.
   - Verify stock math, serial/part identity, requisition state, permissions, and duplicate-submit protection.
   - If no test harness exists, create a safe test plan and/or temporary diagnostic code; do not run destructive tests against live data.
7. **Benchmark and report**
   - Report measured timings only when actually measured. Never invent speedups.
   - Include baseline vs optimized duration, sample size/data volume, and measurement method.
   - If measurement isn't available, state that the change is expected to reduce service calls or complexity, not that it has proven faster.
   - Provide a concise summary of changed files, risks, test results, and rollback instructions.

## Optimization rules

### Google Sheets / Apps Script
- Prefer one `getValues()` call per required block over per-cell calls.
- Prefer `setValues()` for bulk writes; ensure dimensions exactly match the target range.
- Do not call Spreadsheet service methods inside loops unless the loop is demonstrably small and unavoidable.
- Avoid repeatedly calling `getDataRange()` if the same data is already loaded.
- Determine last row/column carefully; handle empty sheets and header-only sheets.
- Avoid reading entire sheets when a bounded range or indexed table can serve the request.
- Minimize formatting operations; batch formatting and avoid formatting unchanged cells.
- Keep execution quotas and maximum runtime in mind. Use chunking for very large data sets, but preserve ordering and atomicity requirements.
- Use `LockService` only where needed to protect shared writes; minimize lock duration and avoid holding locks during expensive reads/calculations if safe.
- Never remove locks, validation, or duplicate-submit protections solely to improve speed.

### Calculation and lookup
- Replace repeated linear searches with a `Map`/index when keys are stable and lookup frequency justifies it.
- Avoid nested scans of transaction rows against each part; aggregate once by key when appropriate.
- Keep numeric normalization explicit: blank, string, zero, negative, and decimal values must follow existing rules.
- Use a single canonical part/serial key function only if the current code's matching rules are understood.
- Preserve current rounding, units, and date/time semantics. Do not silently change precision or timezone behavior.
- Prefer deterministic, pure calculation helpers that can be tested independently of Apps Script services.

### Caching
- Cache only derived or read-mostly data with a clearly understood freshness requirement.
- Document cache key, TTL, size limits, and invalidation triggers.
- Invalidate/update cache after every write that changes cached data, including issue, return, receipt, stock adjustment, count reconciliation, part-master edits, and any other relevant mutation found in code.
- Do not rely on cache as the authoritative inventory ledger.
- Do not cache permission-sensitive results across users unless the key includes the relevant identity/role and authorization is rechecked.
- Treat cache misses and cache errors as normal; always fall back to the source of truth.
- If stale inventory could permit over-issue, do not use cached stock for authorization or final transaction validation.

### Client-side performance
- Inspect `google.script.run` calls and UI event handlers for duplicate requests.
- Avoid fetching full records when the UI needs only a summary.
- Debounce user-triggered search only where it improves UX and does not delay required actions.
- Prevent stale responses from overwriting newer search results.
- Keep loading, error, and success states intact.
- Do not change accessibility or keyboard behavior as a side effect.

## Inventory integrity: non-negotiable
- Do not change stock formulas or transaction semantics without explicit approval.
- Do not bypass server-side validation or permissions.
- Do not remove transaction logs, audit history, approval states, locks, or duplicate-submit guards.
- For stock-affecting operations, validate against the authoritative data inside the protected transaction/write path.
- Never make a speed optimization that can allow overselling/over-issuing, double posting, lost updates, or mismatched part/serial records.
- Cache is an optimization, never the source of truth for a write decision.

## Output format
For each optimization task, return:

### Findings
- Target function/file
- Evidence of bottleneck
- Current complexity/service-call pattern

### Plan
- Minimal change
- Expected improvement (qualitative unless measured)
- Risks and safeguards

### Changes
- Files changed
- Explain behavior-preserving changes

### Validation
- Cases tested
- Before/after result comparison
- Benchmark table if measured; otherwise explicitly say “not measured”

### Rollback
- How to revert the isolated change safely

## Stop and ask
Ask the user before:
- Changing stock formulas, business rules, workflows, approval behavior, or data schema.
- Deleting, migrating, or rewriting existing records.
- Introducing a new external service, dependency, or paid API.
- Making cache freshness weaker for stock/availability decisions.
- Deploying to production or changing live Apps Script deployments.

## Do not
- Claim you inspected files that you have not actually opened.
- Invent spreadsheet names, column mappings, performance numbers, or test results.
- Make broad rewrites for a performance request.
- Optimize solely for fewer lines of code.
- Expose secrets, tokens, spreadsheet IDs, user PINs, or personal data in logs, reports, or test fixtures.
