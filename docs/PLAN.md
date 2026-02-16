# PLAN.md — Pause/Stop Timer Semantics Fix

## Root Cause
Current implementation tracks only one active state and one segment stream. Pressing Pause closes the only active segment, which stops both partial and total elapsed time.

## Required Behavior
- **Pause** must pause only **partial** time.
- **Total** time must continue while paused.
- **Stop** must stop both total and partial timing.

## Implementation Plan
1. Split tracking into two streams:
   - `total_sessions` (start/stop only)
   - `partial_segments` (start/pause/resume/stop)
2. Add timer state flags:
   - `is_total_active`
   - `is_partial_active`
3. Controls:
   - `Start` (when stopped) starts both total + partial
   - `Pause` (when partial active) pauses partial only
   - `Resume` (when total active but partial paused) resumes partial
   - `Stop` (when total active) stops both
4. Stats:
   - Partial (today): sum of partial segments overlapping today
   - Total (all-time): sum of total sessions, including currently running session
5. DB migration to preserve existing installs where possible.

## Verification
- Start timer → both counters increase.
- Press Pause → partial freezes; total keeps increasing.
- Press Resume → partial continues.
- Press Stop → both stop immediately.
