# YT Probe 0.2.8 — FL-365 door fix · ONE careful review pass (probe exception)

Date: 2026-11-21 · Tree: ytprobe-tvos, 0.2.7/18 → 0.2.8/19 · Reviewer: coordinator (single pass, per probe-app exception to the 3-round law)

## Scope (exactly the FL-365 fix, nothing else)
In the Probe 4 sign-in door (also used by Probe 20), ALL auto-drive at any
verification/challenge step is disabled:
- 'Try another way' is never JS-clicked by the app again.
- No verification method is ever auto-picked or auto-clicked on a timer.
- No click is ever retried by the app.
- A chooser-row click fires only after a FRESH inventory scan confirms the
  row is on the page at that moment; otherwise nothing is clicked.
- An unrecognised page stops the automation: the log says so and control
  stays with the owner; the WebView stays mounted, visible and tappable.
Email/password/code fill on the standard pages is unchanged.

## Changes
### YTProbe/ProbeDoor.swift
- Header: 0.2.8 delta bullet added; D-3 and 0.1.4 bullets annotated as removed.
- START banner no longer claims "JS-click steering" — states the 0.2.8 rule.
- `tick()`: the password-method retry loop (auto-click on the 2 s tick, up to
  6 tries) REMOVED. The tick now only observes step transitions.
- `clickTryAnotherWay()` REMOVED (function + its native button in the view;
  hint text now tells the owner the app does not auto-drive at this step).
- `scheduleChooserRetry()` REMOVED (the blind +3 s re-click of the Tap Yes row).
- `clickChooserRowRetry` JS payload REMOVED with its only caller.
- `clickChooser(_:)`: fresh-confirm gate added — re-scans the chooser
  inventory at tap time; the tapped row's kind must appear in THIS scan or
  nothing is clicked and the stale button removes itself. One tap = at most
  one click (needle loop breaks on the first 'clicked'; a 'notfound' outcome
  dispatches no click in the page). No retry is scheduled after the click.
- `detectChooserRows`: dropped the `chooserInventoried` write (its only
  consumer was the removed loop); the no-rows log line now states the
  stop-and-hand-control rule explicitly.
- State removed: `passwordMethodArmed`, `passwordMethodTries`,
  `chooserInventoried`.
### YTProbe/ProbeWeb.swift
- `clickTryAnotherWay` and `clickPasswordMethod` payloads REMOVED (replaced
  by an explanatory comment). `doorProbe`, `domInventory`, `chooserRows`,
  `chooserStep`, fill payloads untouched.
### project.yml
- MARKETING_VERSION / CFBundleShortVersionString 0.2.7 → 0.2.8;
  CURRENT_PROJECT_VERSION / CFBundleVersion 18 → 19 (BOTH pairs).

## Pass checks
1. Dangling references: grep over the whole tree for every removed symbol
   (clickTryAnotherWay, clickPasswordMethod, passwordMethodArmed/Tries,
   chooserInventoried, scheduleChooserRetry, clickChooserRowRetry) — hits
   ONLY in the new explanatory comments. ✓
2. Normal-flow stall check: email → password progression depends only on the
   owner's native fill buttons (untouched) and the page's own controls;
   `tick()` still detects every step transition and `onChallenge()` still
   runs the read-only DOM inventory + chooser scan, so chooser buttons still
   appear at the challenge step. Nothing in the removed code sat on the
   email/password path. ✓
3. Remaining clicks inventory (whole door): fill email (owner tap), fill
   password (owner tap), fill code + Next/Verify (owner tap), chooser row
   (owner tap, fresh-confirmed, single, no retry), focus-page (observation).
   Automatic clicks at verification/challenge steps = 0. ✓
4. Brace/paren balance: 0/0 in both edited Swift files (rough static check;
   CI is the first real compiler — no local Swift toolchain). ✓
5. Probe targets untouched: L1JzJVZA6WU ×7, f-ZSFRsMW_4 ×7 in tree;
   the wrong-title vid 4rdOxL9mqVk ×0. ✓
6. Kept deliberately (noted, not defects): `scanChooser(allowRetry:)`'s
   rescan branch is now unreachable with `true` — it is a read-only scan,
   not a click, and keeping it keeps the diff minimal;
   `challengeInventoried` remains as vestigial write-only state.

## Verdict
CLEAN — one pass, no findings requiring changes. Ready to push.
