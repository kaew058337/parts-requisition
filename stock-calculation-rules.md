# Stock calculation integrity

Before optimizing any stock calculation, document the current formula and the transaction types that affect it from the repository code.

## Validation matrix
Test the existing rules for:
- opening/current balance
- receipt or replenishment
- issue/requisition
- return
- borrow/loan and loan return (if present)
- adjustment
- physical count/reconciliation
- reserved/pending quantities (if present)
- kits or bundled parts (if present)
- cancelled/reversed transactions
- duplicate submission
- serialized vs non-serialized parts
- zero, blank, negative, and fractional quantities (if allowed)

## Required invariants
- Same input history must yield the same stock result before and after optimization.
- A transaction must not be applied twice.
- Part and serial identifiers must remain associated correctly.
- A write that changes stock must invalidate/update any relevant derived cache.
- Final validation for a stock-changing transaction must use authoritative state, not a stale cache.

Do not assume the stock formula is simply received minus issued. Discover the project's actual formula and lifecycle.
