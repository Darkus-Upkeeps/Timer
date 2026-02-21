# PLAN.md — Edit-All Values + Datestamp Restore

## Root Cause
Current restored UI supports editing timer metadata (name/product) but does not expose correction controls for recorded time values (partial/total). Datestamp display from earlier commits was also dropped during refactors.

## Target Behavior
1. **Edit function can adjust all relevant values**
   - Name
   - Product
   - Partial time (today correction)
   - Total time (all-time correction)
2. **Datestamp is visible again**
   - Show timer created date on timer cards
   - Preserve existing data for older timers (fallback when missing)
3. **Printable PDF report export**
   - Generate Zeitanachweis-style PDF
   - Include timer name, product, date, start, end, pause, duration, totals
   - Include signature section (Signatur line)

## Implementation Plan
1. **Schema update (safe migration)**
   - Add `created_at_ms` to `timers` (default now for new rows, backfill old rows).
2. **Time correction model**
   - Add correction columns on `timers`:
     - `partial_adjust_sec` (default 0)
     - `total_adjust_sec` (default 0)
   - Keep raw sessions/segments immutable; apply correction at read time.
3. **Edit dialog upgrade**
   - Add inputs for partial and total correction (seconds/minutes UX).
   - Validate no invalid numbers.
4. **Computation updates**
   - Timer cards: displayed Partial/Total = computed base + adjustment.
   - Reports: include partial adjustments where relevant.
5. **Datestamp UI**
   - Render `Created: YYYY-MM-DD HH:mm` on timer cards.
6. **Verification**
   - Create timer -> datestamp shows.
   - Edit name/product/time corrections -> values update instantly.
   - Report reflects adjusted partial values.
   - Updater flow remains unchanged.

## Tradeoff
Using adjustment fields avoids rewriting historical segments and keeps correction operations reversible/auditable.
