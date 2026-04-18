# First Real Human Pair-Session Checklist

Use this checklist before spending a real human session on the control-vs-treatment workflow.

## Prerequisites

- Windows lab machine with `hl-bots-ai.sln` building as `Release|Win32`
- `scripts\preflight_real_pair_session.ps1` reports either `ready-for-human-pair-session` or `ready-with-warnings`
- HLDS lab paths resolve under `lab\`
- `scripts\run_control_treatment_pair.ps1` is available
- default treatment profile remains `conservative`

## Default Pair Workflow

Run this first:

```powershell
powershell -NoProfile -File .\scripts\preflight_real_pair_session.ps1
```

Then prefer the guided live workflow:

```powershell
powershell -NoProfile -File .\scripts\run_guided_live_pair_session.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -ControlPort 27016 -TreatmentPort 27017 -DurationSeconds 80 -WaitForHumanJoin -HumanJoinGraceSeconds 120 -TreatmentProfile conservative -SkipSteamCmdUpdate -SkipMetamodDownload
```

Use `-AutoStopWhenSufficient` only when you want the guided runner to request a safe early stop after the live monitor reaches a sufficient verdict.

Use rehearsal mode when you need to validate the guided auto-stop success branch before the next real session:

```powershell
powershell -NoProfile -File .\scripts\run_guided_live_pair_session.ps1 -RehearsalMode -RehearsalFixtureId strong_signal_keep_conservative -RehearsalStepSeconds 2 -Map crossfire -BotCount 4 -BotSkill 3 -ControlPort 27016 -TreatmentPort 27017 -DurationSeconds 18 -WaitForHumanJoin -HumanJoinGraceSeconds 20 -MinHumanSnapshots 3 -MinHumanPresenceSeconds 60 -MinPatchEventsForUsableLane 2 -MinPostPatchObservationSeconds 20 -TreatmentProfile conservative -AutoStartMonitor -AutoStopWhenSufficient -MonitorPollSeconds 1 -RunPostPipeline
```

The guided runner stays thin:

- it still runs `scripts\preflight_real_pair_session.ps1`
- it still uses `scripts\run_control_treatment_pair.ps1` for the pair capture
- in rehearsal mode it swaps only the pair-capture step for `scripts\run_guided_pair_rehearsal.ps1`
- it still uses `scripts\monitor_live_pair_session.ps1` for live evidence-sufficiency decisions
- it still uses the same review, shadow, scoring, registry, and responsive-gate helpers after the run
- in rehearsal mode it writes the validation-only registry under `guided_session\registry\` instead of the real ledger

If you need the old manual flow, start the live pair like this:

```powershell
powershell -NoProfile -File .\scripts\run_control_treatment_pair.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -ControlPort 27016 -TreatmentPort 27017 -DurationSeconds 80 -WaitForHumanJoin -HumanJoinGraceSeconds 120 -TreatmentProfile conservative -SkipSteamCmdUpdate -SkipMetamodDownload
```

Then start the live monitor in a second terminal:

```powershell
powershell -NoProfile -File .\scripts\monitor_live_pair_session.ps1 -UseLatest -PollSeconds 5 -StopWhenSufficient
```

The pair runner also prints an exact threshold-aware `-PairRoot` monitor command for that live pair pack. The guided runner can auto-start that same monitor logic and, after the run, writes `session_outcome_dossier.json`, `session_outcome_dossier.md`, `guided_session\final_session_docket.json`, and `guided_session\final_session_docket.md` under the pair root.

Default ports and lanes:

- control lane: `127.0.0.1:27016`
- treatment lane: `127.0.0.1:27017`
- control lane role: no-AI baseline with `jk_ai_balance_enabled 0` and no sidecar
- treatment lane role: AI treatment with the `conservative` profile

## Why Conservative Is The Default

- it demands more human signal before claiming the lane is useful
- it reacts more slowly near the boundary, which is safer for the first real human session
- it is the cleanest way to learn whether the treatment lane is too quiet before considering `responsive`

## Operator Sequence

1. Run preflight and stop only if the verdict is `blocked`.
2. Start the guided workflow unless you explicitly need the manual helper-by-helper flow.
3. Read the printed control join target, treatment join target, monitor status or exact monitor command, pair output root, and final-docket target.
4. Join the control lane first.
5. Stay in the control lane for about the configured `-MinHumanPresenceSeconds` window. Treat roughly 60 seconds or more as the minimum useful target when using the current live defaults.
6. Let the runner advance to the treatment lane, then join the treatment lane second.
7. If the guided runner auto-started the monitor, let it keep polling. If not, run the printed monitor command manually.
8. Stay in the treatment lane until the monitor reaches `sufficient-for-tuning-usable-review` or `sufficient-for-scorecard`.
9. Keep the pair running longer when the monitor still says any `waiting-for-*` verdict.
10. Use auto-stop only when you want the workflow to request an early stop on the sufficient verdicts above and nowhere else.
11. Use manual stop instead when you want more observation time, operator judgment, or a no-human validation run that should end honestly as insufficient-data.
12. Read `session_outcome_dossier.md` first after the run. Use `guided_session\final_session_docket.md` as the quick pointer to it.
13. Run `scripts\build_latest_session_outcome_dossier.ps1 -PairRoot <pair-root>` later if you need to rebuild the dossier after rerunning scorecard, certification, or planner helpers.
14. Read `next_live_plan` only when you need the full session-target detail that sits behind the dossier's next-action sentence.
15. If the dossier says manual review is needed, continue into the detailed helper artifacts (`review_latest_pair_run`, shadow review, scorecard, registry summary, responsive gate).

## What Counts As Insufficient Data

- no humans join either lane
- a human joins only briefly and does not stay long enough to satisfy the minimum human-presence window
- treatment never patches while humans are present
- there is no meaningful post-patch observation window after a treatment patch

These runs are at most `plumbing-valid only` or `partially usable`.

## What Counts As Usable Signal

- a human stays in both lanes long enough to satisfy the minimum human-presence gate
- control and treatment both remain launch-healthy
- treatment patches while humans are present
- there is enough time after a human-present patch to observe whether the treatment changed the live lane

This is the minimum bar for `tuning-usable`. Multiple grounded post-patch windows are what move a pair toward `strong-signal`.

## How To Read The Live Monitor

- `waiting-for-control-human-signal`: control still lacks enough human signal, so keep the control lane running.
- `waiting-for-treatment-human-signal`: control cleared the gate, but treatment still needs more grounded human presence.
- `waiting-for-treatment-patch-while-humans-present`: treatment humans stayed long enough, but the AI has not yet produced enough live human-present patch activity.
- `waiting-for-post-patch-observation-window`: treatment already patched while humans were present, but the post-patch observation time is still too short to stop honestly.
- `sufficient-for-tuning-usable-review`: the minimum honest stop bar is met during the live run. You can stop the pair and move to review.
- `sufficient-for-scorecard`: the pair pack is already finalized and the same grounded stop bar is satisfied, so the scorecard helper can run immediately.
- `insufficient-data-timeout`: the pair ended before the grounded evidence gate cleared. Treat it as insufficient data, not as tuning proof.
- `blocked-no-active-pair-run`: the monitor cannot find an active pair root to observe.

`sufficient-for-tuning-usable-review` means both lanes cleared the human gate, treatment patched while humans were present, and the post-patch observation window is already meaningful. `sufficient-for-scorecard` means the same evidence bar is satisfied and the pair artifacts are already complete enough for `scripts\score_latest_pair_session.ps1`.

Stop the live session only on one of the `sufficient-*` verdicts. Keep it running on the `waiting-*` verdicts. If the monitor ends on `insufficient-data-timeout`, keep the artifacts as plumbing or weak-signal evidence only and schedule another conservative live pair before trying anything riskier.

Auto-start monitor means the guided workflow runs the live monitor for you and keeps writing `live_monitor_status.json` / `live_monitor_status.md` into the active pair root. Auto-stop means the guided workflow requests a safe early stop only after one of the `sufficient-*` verdicts appears. It must never stop on `waiting-*`, `insufficient-data-timeout`, or `blocked-no-active-pair-run`.

In rehearsal mode, also inspect `guided_session\monitor_verdict_history.ndjson`. It should show the staged progression through the waiting states before the sufficient verdict appears, and only then should the stop request be written.

## Files To Inspect After The Run

Open these in order:

1. `session_outcome_dossier.md`
2. `guided_session\final_session_docket.md`
3. `scorecard.md`
4. `pair_summary.md`
5. `comparison.md`
6. treatment `summary.md` or `session_pack.md` if the treatment lane looks too quiet
7. control `summary.md` if the control lane looks weak or sparse

The fastest way to review the newest pair is:

```powershell
powershell -NoProfile -File .\scripts\review_latest_pair_run.ps1
```

Then score it with:

```powershell
powershell -NoProfile -File .\scripts\score_latest_pair_session.ps1
```

Then certify whether the pair counts as real grounded promotion evidence:

```powershell
powershell -NoProfile -File .\scripts\certify_latest_pair_session.ps1
powershell -NoProfile -File .\scripts\certify_latest_pair_session.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
```

Run the shadow review against the latest pair pack before you decide whether `responsive` is worth a real follow-up session:

```powershell
powershell -NoProfile -File .\scripts\run_shadow_profile_review.ps1 -UseLatest -Profiles conservative default responsive
```

Or target a specific saved pair pack:

```powershell
powershell -NoProfile -File .\scripts\run_shadow_profile_review.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack> -RequireHumanSignal -MinHumanSnapshots 2 -MinHumanPresenceSeconds 40
```

Then register it into the ledger:

```powershell
powershell -NoProfile -File .\scripts\register_pair_session_result.ps1
```

Then summarize the accumulated registry:

```powershell
powershell -NoProfile -File .\scripts\summarize_pair_session_registry.ps1
```

Then evaluate whether the first live `responsive` trial is actually allowed:

```powershell
powershell -NoProfile -File .\scripts\evaluate_responsive_trial_gate.ps1
```

How to read the final session docket:

- `control lane verdict`, `treatment lane verdict`, and `pair classification` come from the saved pair pack
- `scorecard recommendation` comes from `scripts\score_latest_pair_session.ps1`
- `shadow recommendation` comes from `scripts\run_shadow_profile_review.ps1`
- `registry recommendation state` comes from `scripts\summarize_pair_session_registry.ps1`
- `responsive gate verdict` comes from `scripts\evaluate_responsive_trial_gate.ps1`
- the docket's primary operator action stays conservative-first and honest about insufficient evidence
- in rehearsal mode the docket must also say the evidence is `synthetic`, `rehearsal`, and `validation only`

How to read grounded evidence certification:

- `grounded_evidence_certificate.json` is the machine-readable answer to whether the pair counts toward future responsive-promotion thresholds
- `grounded_evidence_certificate.md` is the human-readable explanation of the same verdict
- `counts toward promotion` means the session is real live evidence, not rehearsal, not synthetic, both lanes cleared the minimum human-signal gate, treatment patched while humans were present, a meaningful post-patch observation window exists, and the pair cleared `tuning-usable` or stronger
- `workflow validation only` means the workflow behaved correctly, but the run must stay excluded from promotion logic
- rehearsal, synthetic, no-human, plumbing-valid-only, comparison-insufficient-data, insufficient-data, and weak-signal sessions do not count toward responsive promotion

## If No Humans Join

- keep the run only as plumbing validation
- do not claim tuning evidence
- rerun later with a real participant and keep the same conservative treatment profile first

## If Treatment Never Patches While Humans Are Present

- inspect `comparison.md` and the treatment lane `summary.md`
- confirm whether humans were present long enough for treatment to react
- if the pair still says treatment stayed too quiet relative to control, only then consider a later follow-up with `responsive`

## How To Interpret The Scorecard

- `too quiet`: humans were present long enough to compare lanes, and conservative still looked too quiet relative to control under grounded live evidence
- `appropriately conservative`: conservative produced grounded human-present patch evidence and did not look oscillatory or overactive
- `inconclusive`: human presence, patch timing, or post-patch windows were still too weak to justify a profile decision
- `too reactive`: the treatment lane looked oscillatory or violated a guardrail and needs manual review before another live profile choice

## How To Use The Recommendation

- `keep-conservative-and-collect-more`: conservative stays the next live default
- `treatment-evidence-promising-repeat-conservative`: repeat conservative before changing profile
- `weak-signal-repeat-session`: collect another conservative session because the live evidence stayed weak
- `conservative-looks-too-quiet-try-responsive-next`: responsive is justified as the next candidate only because conservative stayed too quiet under usable human presence
- `responsive-too-reactive-revert-to-conservative`: grounded responsive evidence already says the live treatment overreacted, so the next live profile should move back to conservative
- `insufficient-data-repeat-session`: reject the session as tuning evidence and repeat the live pair first
- `manual-review-needed`: inspect `comparison.md`, `scorecard.md`, and the treatment lane summary before choosing the next action

## How To Read Shadow Review

- `keep-conservative`: the captured lane does not justify a live profile change yet.
- `conservative-and-default-similar`: shadow `default` behaved materially like the captured conservative lane, so switching profiles would spend human time without new grounded evidence.
- `insufficient-data-no-promotion`: the captured lane never cleared the human-signal gate strongly enough for promotion. Shadow replay should not be used to justify `responsive`.
- `conservative-looks-too-quiet-responsive-candidate`: conservative looks too quiet and responsive would have created more grounded human-present treatment evidence without tripping the guardrails. Treat this as a candidate only, not proof.
- `responsive-would-have-overreacted`: responsive looked too reactive in counterfactual replay, so conservative should remain live.
- shadow review is useful before spending a real live session on `responsive` because it gives the operator a bounded "what if" answer from the same captured telemetry instead of a blind promotion.

## Cross-Session Ledger

- `scripts\register_pair_session_result.ps1` appends the reviewed and scored pair pack into `lab\logs\eval\registry\pair_sessions.ndjson`
- registration defaults to the newest pair pack and skips duplicate pair packs by default
- registration also writes `grounded_evidence_certificate.json` and `grounded_evidence_certificate.md` into the pair root
- optional notes can be linked with `-NotesPath` or by placing a notes file in the pair root; missing notes never fail the registration step
- `scripts\summarize_pair_session_registry.ps1` writes `registry_summary.json`, `registry_summary.md`, `profile_recommendation.json`, and `profile_recommendation.md`
- `scripts\summarize_pair_session_registry.ps1 -EvaluateResponsiveTrialGate` can also refresh the latest responsive-trial gate in the same pass
- `scripts\summarize_pair_session_registry.ps1 -EvaluateNextLiveSessionPlan` can also refresh `next_live_plan.json` and `next_live_plan.md` in the same pass
- `scripts\analyze_latest_grounded_session.ps1` writes `grounded_session_analysis.json`, `grounded_session_analysis.md`, `promotion_gap_delta.json`, and `promotion_gap_delta.md` for the latest pair or a specific `-PairRoot`
- `scripts\build_latest_session_outcome_dossier.ps1` writes `session_outcome_dossier.json` and `session_outcome_dossier.md` for the latest pair or a specific `-PairRoot`
- the registry summary now distinguishes total registered sessions from certified grounded sessions, non-certified excluded sessions, workflow-validation-only sessions, and excluded sessions by reason
- conservative remains the default next live profile until the registry shows repeated certified grounded evidence that responsive is justified
- responsive should be rejected or reverted when grounded responsive evidence looks too reactive

## Outcome Dossier

- run `powershell -NoProfile -File .\scripts\build_latest_session_outcome_dossier.ps1` after the normal post-run pipeline or target a specific pair with `-PairRoot`
- the dossier is the operator-facing consolidation layer: it answers whether the latest session counted as grounded evidence, whether it reduced the promotion gap, what changed in the gate/planner state, and what the exact next live action is now
- scorecard alone still answers how the pair behaved
- certification alone still answers whether the pair counts toward promotion
- the next-live planner still answers the full current gap and detailed next session target
- the dossier stitches those answers together and adds the before-vs-after comparison for the latest session
- `what changed because of this session?` is the evidence-accounting block. Read those deltas literally
- non-grounded sessions may legitimately leave the dossier in a no-impact state. Rehearsal, synthetic, no-human, weak-signal, and otherwise excluded sessions should not pretend to move the real promotion gap

## Latest-Session Delta

- run `powershell -NoProfile -File .\scripts\analyze_latest_grounded_session.ps1` after scoring, certification, registration, summary, gate, and planner refresh
- use `-PairRoot` when the newest saved pair pack is not the real live pair you want to explain
- `grounded_session_analysis.md` answers whether the latest pair became certified grounded evidence, whether it counted toward promotion, whether it created the first grounded conservative session, whether it added grounded conservative-too-quiet evidence, and whether the next objective changed
- `promotion_gap_delta.md` is the compact before/after delta for grounded sessions, grounded too-quiet counts, strong-signal counts, responsive blockers, gate state, and next objective
- non-grounded sessions can still be the correct latest-session answer. Rehearsal, synthetic, no-human, weak-signal, and otherwise excluded live runs should report `no-impact-non-grounded-session` instead of pretending the promotion gap moved
- "the latest session changed something" means the helper shows a real delta in certified grounded evidence, next-step recommendation, or responsive blocker state. If those stay flat, the honest answer is that the project is still blocked in the same state

## Next-Live Planner

- `scripts\plan_next_live_session.ps1` is the promotion-gap helper for the next real live session
- it writes `next_live_plan.json` and `next_live_plan.md` under `lab\logs\eval\registry\`
- it uses certified grounded evidence only when it computes how much promotion evidence is still missing
- rehearsal, synthetic, workflow-validation-only, no-human, weak-signal, insufficient-data, and other non-certified live sessions do not reduce the real responsive-promotion gap
- "evidence gap" means the configured threshold minus the current certified grounded count for that evidence type
- the planner tells the operator whether the next session should aim for first grounded certification, another grounded conservative session, repeated grounded conservative-too-quiet evidence, a responsive trial, or manual review
- the planner also prints the next session target: conservative vs responsive profile, unchanged no-AI control lane, minimum human snapshots, minimum human-presence window, minimum patch-while-human-present events, minimum post-patch observation window, whether the session can reduce the gap, and whether another conservative session would still be required afterward

Run it after the registry summary and before choosing the next live slot:

```powershell
powershell -NoProfile -File .\scripts\plan_next_live_session.ps1
```

Use it as the operator answer to "what must the next conservative session prove?" The scorecard and certification are per-pair. The registry summary is cross-session. The responsive gate is the final responsive go/no-go check. The next-live planner is the bridge that turns those outputs into a concrete next-session objective.

## Responsive Trial Gate

- `scripts\evaluate_responsive_trial_gate.ps1` is the explicit go/no-go check for the first real live `responsive` treatment session
- it writes `responsive_trial_gate.json`, `responsive_trial_gate.md`, `responsive_trial_plan.json`, and `responsive_trial_plan.md` under `lab\logs\eval\registry\`
- the gate reads the registry first, then uses `registry_summary.json` and `profile_recommendation.json` when they are already present
- gate thresholds live in `ai_director\testdata\responsive_trial_gate.json` and are intentionally strict: repeated certified grounded conservative too-quiet evidence can open the gate, but rehearsal, synthetic-only, no-human, insufficient-data, weak-signal, validation-only, or one-off noisy evidence cannot
- synthetic fixtures help validate the gate logic, but synthetic-only evidence must never unlock the real live responsive trial

Read the next live action like this:

- `responsive-trial-not-allowed`: the gate is still closed because the real evidence is still insufficient, weak, or synthetic-only
- `collect-more-conservative-evidence`: some real grounded conservative evidence exists, but not enough repeated too-quiet evidence exists yet
- `keep-conservative`: real grounded conservative evidence already looks acceptable, so responsive should stay blocked
- `responsive-trial-allowed`: one bounded live responsive trial is justified, and `responsive_trial_plan.md` becomes the operator plan
- `responsive-revert-recommended`: grounded responsive evidence already shows overreaction, so the live default should move back to conservative
- `manual-review-needed`: the grounded evidence is conflicting or risk-signaling and needs an operator read before another live profile choice

If the gate is blocked, treat `responsive_trial_plan.md` as a "not yet" note, not as a ready runbook. If the gate is open, the plan file gives the exact live responsive trial settings and rollback rule.

## Synthetic Fixture Validation

- synthetic pair/session fixtures live under `ai_director\testdata\pair_sessions\`
- they are deterministic, clearly marked synthetic, and shaped like real pair packs so the same post-run tools can consume them
- the fixture families cover insufficient-data, weak-signal, keep-conservative, conservative-too-quiet responsive-candidate, responsive-too-reactive revert, and ambiguous manual-review branches
- use them to validate the decision stack before another live session, not to replace real human evidence
- a fixture that stays insufficient-data or weak-signal must never justify promoting `responsive`
- synthetic fixtures can exercise the gate in validation mode, but they must never unlock the real live gate by themselves

Regenerate the fixtures if their deterministic source definitions change:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\common.ps1; `$pythonExe = Get-PythonPath -PreferredPath ''; & `$pythonExe .\scripts\generate_pair_session_fixtures.py"
```

Run the dedicated fixture-backed decision validation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\common.ps1; `$pythonExe = Get-PythonPath -PreferredPath ''; & `$pythonExe -m unittest ai_director.tests.test_pair_session_fixtures"
```

Run the optional compact fixture demo when you want a one-shot branch summary:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_fixture_decision_demo.ps1
```

Use the guided rehearsal instead when you need to validate the real operator workflow rather than the broader fixture suite:

- the live monitor should walk the same waiting states as a real run
- `-AutoStopWhenSufficient` should stop only after `sufficient-for-tuning-usable-review`
- the final monitor verdict after pair finalization should be `sufficient-for-scorecard`
- `guided_session\final_session_docket.md` should clearly say the evidence origin is rehearsal
- `session_outcome_dossier.md` should clearly say the session is workflow-validation-only and that the real responsive gate did not move
- `guided_session\registry\responsive_trial_gate.json` should still stay closed because rehearsal evidence must never unlock responsive

## Optional Session Notes

- `docs\first-live-pair-notes-template.md` is a lightweight place to jot down who joined, how long they stayed, and whether treatment felt too quiet or too reactive

## Preflight Verdict Meanings

- `ready-for-human-pair-session`: required scripts, build output, ports, and profile selection are ready without current warnings
- `ready-with-warnings`: the pair can be run, but at least one non-blocking prerequisite or optional helper needs attention
- `blocked`: do not spend a human session yet; fix the reported blockers first
