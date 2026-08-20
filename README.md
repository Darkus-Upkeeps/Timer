# Timer

Timer for work purposes

## Auto-stop

A timer can stop itself after a given amount of **worked** time. The limit is a
**budget for the work day**, not for a single run of the timer:

- Pauses do not count. Only time the timer actually ran is charged to the
  budget, so a lunch break does not eat into the 7 hours.
- Pausing, stopping and starting again during the day all keep the same
  budget. Working 4h in the morning and starting the timer again after the
  break leaves 3h of a 7h limit — not another 7h.
- The stop is recorded at the exact moment the limit was reached, even when the
  app was closed at the time. Opening the app corrects the session afterwards
  instead of counting time up to the moment it was opened.
- The limit fires once a day. A session started *after* it fired is treated as
  deliberate overtime and keeps running, so the timer cannot swallow work that
  is knowingly done past the limit.
- A shift that started on the previous day (night shift) keeps the budget of
  the day it started in: midnight does not hand out a second one.
- Changing the limit arms it again for the current day.

The remaining budget is shown on the timer card, on the dashboard and in the
status-bar notification, and the running notification names the projected
stop time.
