# PLAN.md — Restore Core Timer Features (Multi-Timer + Reports) while keeping Updater

## Root Cause
During updater integration/recovery, `lib/main.dart` was replaced with a simplified single-timer UI to stabilize release/signing and OTA updates. That removed prior core product capabilities.

## Features to Restore
1. **Multiple spawnable timers**
   - Create/edit/delete timers
   - Independent elapsed tracking per timer
   - Start/stop per timer
2. **Report feature**
   - Restore report generation/export path from prior app behavior
   - Include per-timer totals and date range aggregation
3. **Keep new updater system intact**
   - Stable-only update lane (`main` + `latest-stable`)
   - PAT-secured private release fetch

## Implementation Plan
1. **Reconstruct data model + persistence**
   - Add `timers` table and `time_entries` (or equivalent) for multi-timer records.
   - Migrate/initialize DB safely.
2. **Rebuild timer management UI**
   - Timer list view
   - Add timer dialog
   - Edit/delete actions
   - Per-item controls and running-state UI
3. **Restore reporting**
   - Daily/period summaries
   - Report screen + export/share action
4. **Preserve updater panel**
   - Keep App Updates card with token save/check/install
5. **Validation**
   - Functional test: create multiple timers, run concurrently/sequentially, verify totals
   - Report test: totals match tracked entries
   - Updater test: still checks `latest-stable`

## Risk/Tradeoffs
- Reconstructing features from memory may differ from original UX if legacy source isn’t available.
- Fastest high-confidence path is to recover from previous commits/files where these features existed, then merge updater panel in.

## Deliverables
- Restored multi-timer production flow
- Restored report feature
- Updater still operational
- Updated README with user flow
