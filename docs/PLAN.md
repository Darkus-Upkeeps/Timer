# PLAN.md — Report Sync + Editable Date/Time Controls

## Root Cause
- Report aggregates are based on stored segments and currently do not fully apply edit corrections in all report views/exports.
- Timer edit UI lacks direct date editing.
- Time/date edits currently rely on raw text entry only.

## Target Behavior
1. **Report sync after edits**
   - Any timer edit (name/product/partial/total/date) must immediately reflect in report screen + PDF.
2. **Editable timer date**
   - User can change timer created date/time.
3. **Common date/time pickers**
   - Use native picker controls (date picker + time picker), not only text typing.

## Implementation Plan
1. **Data layer**
   - Ensure `created_at_ms` is writable in timer update API.
   - Ensure report computations apply adjustments consistently.
2. **Edit dialog UX**
   - Add date + time fields with picker buttons.
   - Keep optional manual input fallback, but picker-first.
3. **Report pipeline**
   - Apply corrections to report lines and totals (screen + PDF).
   - Keep weekly/monthly sums aligned with corrected values.
4. **Validation**
   - Edit a timer’s partial/total/date; verify list card, report list, and PDF all update consistently.

## Deliverables
- Synced corrected reports
- Date/time editable via pickers
- Stable updater flow unchanged
