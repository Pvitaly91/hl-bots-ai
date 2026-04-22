# First Real Human Pair-Session Checklist

Use this checklist before spending a real human session on the control-vs-treatment workflow.

## Prerequisites

- Windows lab machine with `hl-bots-ai.sln` building as `Release|Win32`
- `scripts\preflight_real_pair_session.ps1` reports either `ready-for-human-pair-session` or `ready-with-warnings`
- HLDS lab paths resolve under `lab\`
- `scripts\prepare_next_live_session_mission.ps1` is available so the next-session target can be generated before launch
- `scripts\run_current_live_mission.ps1` is available so the next-session target can be launched directly with drift checks instead of being re-entered manually
- `scripts\assess_latest_session_recovery.ps1` is available so an interrupted or suspicious pair can be classified before anyone guesses whether to salvage or rerun it
- `scripts\finalize_interrupted_session.ps1` is available so recoverable interrupted sessions can be finalized without replaying the whole live run
- `scripts\continue_current_live_mission.ps1` is available so the operator can ask one top-level helper to choose no-action, salvage, rerun, or manual review after a partial run
- `scripts\inject_pair_session_failure.ps1` is available so failure branches can be staged safely against rehearsal-only pair roots instead of improvising on live evidence
- `scripts\run_mission_continuation_rehearsal.ps1` is available so the whole failure-and-recovery chain can be rehearsed before the first real human-rich conservative session
- `scripts\run_recovery_branch_matrix.ps1` is available so the full recovery branch suite can be rerun and summarized into one operator-facing readiness certificate before the first real human-rich conservative session
- `scripts\run_first_grounded_conservative_attempt.ps1` is available so the first real conservative evidence-capture attempt can run through the current mission, recovery, and closeout stack while producing one milestone-oriented attempt report
- `scripts\run_human_participation_conservative_attempt.ps1` is available so a launchable local client can be turned into a real control-then-treatment conservative participation attempt with explicit human-participation tracking
- `scripts\run_next_grounded_conservative_cycle.ps1` is available so the next live conservative cycle can answer whether the latest run became the second grounded conservative capture, only reduced the gap, or advanced the next objective
- `scripts\guide_control_to_treatment_switch.ps1` is available so the operator can see the exact remaining control-side deficit and wait to switch until control is genuinely safe to leave
- `scripts\guide_treatment_patch_window.ps1` is available so the operator can see the exact remaining treatment-side grounded patch deficit and wait to leave treatment until human-present patch evidence is genuinely ready
- `scripts\guide_conservative_phase_flow.ps1` is available so the live sequence can be watched through one current phase and one next action instead of juggling separate phase helpers manually
- `scripts\review_counted_pair_evidence.ps1` is available so a historically counted pair can be reconciled against authoritative evidence before another live spend when the planner says `manual-review-before-next-session`
- `scripts\reconcile_pair_metrics.ps1` is available so a counted pair with stale treatment-side or monitor-derived metrics can be reconciled and refreshed without casually changing registry or promotion state
- `scripts\refresh_pair_wrapper_narratives.ps1` is available so the last stale wrapper narratives can be regenerated from canonical evidence and the pair-level manual-review label can be cleared, if safe, without changing registry or promotion state
- `scripts\recompute_after_pair_clearance.ps1` is available so a cleared counted pair can drive an additive downstream recompute before you assume the global responsive gate or next-live plan really changed
- `scripts\review_grounded_evidence_matrix.ps1` is available so the currently counted grounded conservative sessions can be laid out in one explicit matrix before deciding whether the global manual-review state is actually still justified
- `scripts\prepare_strong_signal_conservative_mission.ps1` is available so the mixed counted grounded conservative state can be turned into one stronger-signal conservative mission before spending another live run
- `scripts\run_strong_signal_conservative_attempt.ps1` is available so the strong-signal mission can be spent through the existing client-assisted conservative workflow while recording whether the run actually added the first counted grounded strong-signal conservative session
- `scripts\discover_hldm_client.ps1` is available so local `hl.exe` readiness can be checked explicitly before the live session starts
- `scripts\join_live_pair_lane.ps1` is available so the operator can launch or preview the local client for the control or treatment lane without hand-copying the port
- `scripts\audit_client_presence.ps1` is available so a failed live pair with a launched local client can be diagnosed stage-by-stage before another real attempt is spent
- `scripts\run_client_join_completion_probe.ps1` is available so the launch-to-snapshot chain can be reproduced in one bounded control-lane probe before another full strong-signal conservative session is spent
- `scripts\run_client_join_reliability_matrix.ps1` is available so repeated bounded control-lane probes can be summarized into one reliability matrix and one conservative readiness certificate before another full strong-signal conservative session is spent
- `scripts\audit_probe_lane_startup.ps1` is available so a failed repeated bounded probe can be audited specifically for lane-root materialization, port-ready, and join-invocation failure before another live spend is justified
- `scripts\audit_first_human_snapshot_boundary.ps1` is available so a repeated probe that already reached `entered the game` can be audited specifically for the later boundary between authoritative telemetry history and saved lane summary reflection
- `scripts\evaluate_latest_session_mission.ps1` is available so the post-run mission closeout can be generated after the session
- `scripts\run_control_treatment_pair.ps1` is available
- default treatment profile remains `conservative`

## Default Pair Workflow

Run this first:

```powershell
powershell -NoProfile -File .\scripts\preflight_real_pair_session.ps1
```

Then generate or inspect the current mission brief:

```powershell
powershell -NoProfile -File .\scripts\prepare_next_live_session_mission.ps1
```

Then check whether this machine can launch `hl.exe` automatically:

```powershell
powershell -NoProfile -File .\scripts\discover_hldm_client.ps1
```

Then prefer the mission-driven live workflow:

```powershell
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1
```

When the goal is specifically the first grounded conservative capture attempt, prefer this milestone wrapper instead:

```powershell
powershell -NoProfile -File .\scripts\run_first_grounded_conservative_attempt.ps1
```

When the local client is available and you want the helper to drive the actual control-then-treatment join sequence too, prefer:

```powershell
powershell -NoProfile -File .\scripts\run_human_participation_conservative_attempt.ps1
```

After the first grounded conservative capture already exists, use this milestone helper when the question becomes whether the next cycle produced the second grounded conservative pack or advanced the planner:

```powershell
powershell -NoProfile -File .\scripts\run_next_grounded_conservative_cycle.ps1
```

Inspect the exact mission-derived launch without starting it like this:

```powershell
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1 -DryRun
```

Use `-AutoStopWhenSufficient` only when you want the guided runner to request a safe early stop after the live monitor reaches a sufficient verdict.

Use rehearsal mode when you need to validate the guided auto-stop success branch before the next real session:

```powershell
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1 -RehearsalMode -RehearsalFixtureId strong_signal_keep_conservative -RehearsalStepSeconds 2 -AutoStopWhenSufficient -MonitorPollSeconds 1
```

The guided runner stays thin:

- it still runs `scripts\preflight_real_pair_session.ps1`
- it now runs `scripts\prepare_next_live_session_mission.ps1` before launch and prints the mission brief path, recommended live profile, and current next objective
- it still uses `scripts\run_control_treatment_pair.ps1` for the pair capture
- in rehearsal mode it swaps only the pair-capture step for `scripts\run_guided_pair_rehearsal.ps1`
- it still uses `scripts\monitor_live_pair_session.ps1` for live evidence-sufficiency decisions
- it still uses the same review, shadow, scoring, registry, and responsive-gate helpers after the run
- it snapshots the pre-run mission under `guided_session\mission\` once the pair root exists
- the mission-driven wrapper writes `guided_session\mission_execution.json`, `guided_session\mission_execution.md`, and `guided_session\session_state.json` so later closeout and recovery assessment can distinguish a mission-exact launch from a drifted or interrupted one
- in rehearsal mode it writes the validation-only registry under `guided_session\registry\` instead of the real ledger

If you need the old manual flow, start the live pair like this:

```powershell
powershell -NoProfile -File .\scripts\run_control_treatment_pair.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -ControlPort 27016 -TreatmentPort 27017 -DurationSeconds 80 -WaitForHumanJoin -HumanJoinGraceSeconds 120 -TreatmentProfile conservative -SkipSteamCmdUpdate -SkipMetamodDownload
```

Then start the live monitor in a second terminal:

```powershell
powershell -NoProfile -File .\scripts\monitor_live_pair_session.ps1 -UseLatest -PollSeconds 5 -StopWhenSufficient
```

The pair runner also prints an exact threshold-aware `-PairRoot` monitor command for that live pair pack. The guided runner can auto-start that same monitor logic and, after the run, writes `session_outcome_dossier.json`, `session_outcome_dossier.md`, `mission_attainment.json`, `mission_attainment.md`, `guided_session\mission\next_live_session_mission.json`, `guided_session\mission\next_live_session_mission.md`, `guided_session\mission_execution.json`, `guided_session\mission_execution.md`, `guided_session\final_session_docket.json`, and `guided_session\final_session_docket.md` under the pair root.

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
2. Read `next_live_session_mission.md` or let the mission runner reuse the current brief automatically.
3. For the first grounded conservative milestone attempt, start `scripts\run_human_participation_conservative_attempt.ps1` when `hl.exe` is launchable on this machine. Fall back to `scripts\run_first_grounded_conservative_attempt.ps1` when you need the same mission/closeout stack without automatic local joins. Otherwise start the mission-driven workflow directly unless you explicitly need the manual helper-by-helper flow.
4. After the first grounded conservative capture already exists, prefer `scripts\run_next_grounded_conservative_cycle.ps1` for the next live conservative evidence cycle so the before/after counts and objective shift are recorded explicitly.
5. Read the printed mission brief path, mission-execution preview or pair-root mission-execution path, control join target, treatment join target, join-helper command, monitor status or exact monitor command, pair output root, and final-docket target.
6. If `hl.exe` was found, prefer `scripts\join_live_pair_lane.ps1 -Lane Control -PairRoot <pair-root>` or the printed port-based join helper command. Otherwise use the printed `connect` command manually.
7. Start `powershell -NoProfile -File .\scripts\guide_conservative_phase_flow.ps1 -PairRoot <pair-root> -UseLatest` in a second terminal or rely on the built-in sequential phase-director inside `scripts\run_human_participation_conservative_attempt.ps1`.
8. Stay in the control lane until the phase-director says `phase-control-ready-switch-now`. If it still says `phase-control-stay`, do not leave yet; read the exact remaining control snapshot and seconds deficit.
9. Let the runner advance to the treatment lane, then join the treatment lane second with the corresponding join helper or the printed manual `connect` command.
10. Stay in the treatment lane until the same phase-director says `phase-grounded-ready-finish-now`. If it still says `phase-treatment-waiting-for-human-signal`, `phase-treatment-waiting-for-patch`, or `phase-treatment-waiting-for-post-patch-window`, do not leave yet.
11. Use the narrower control-only or treatment-only helpers only when you intentionally need the deeper single-phase detail; the sequential phase-director is now the preferred live workflow.
12. If the guided runner auto-started the broader live monitor, let it keep polling as a parallel sanity check. If not, run the printed monitor command manually.
13. Use auto-stop only when you want the workflow to request an early stop on the sufficient verdicts above and nowhere else.
14. Use manual stop instead when you want more observation time, operator judgment, or a no-human validation run that should end honestly as insufficient-data.
15. Read `session_outcome_dossier.md` first after the run. Use `guided_session\final_session_docket.md` as the quick pointer to it.
16. Read `mission_attainment.md` immediately after the dossier when you need the exact mission-closeout answer for that run.
17. If the session was interrupted, the operator terminal died, or the artifact stack looks partial, run `powershell -NoProfile -File .\scripts\continue_current_live_mission.ps1 -PairRoot <pair-root> -DryRun` first.
18. If the continuation decision is `salvage-interrupted-session`, rerun the same command with `-Execute` or use the linked `finalize_interrupted_session.ps1` command. Do not replay the live run first.
19. If the continuation decision is `rerun-current-mission` or `rerun-current-mission-with-new-pair-root`, review the linked saved mission or current mission path, then rerun the controller with `-Execute` when you are ready to spend a new pair.
20. If the continuation decision is `session-already-complete-no-action` or `session-already-complete-review-only`, read the linked final docket, mission-attainment closeout, outcome dossier, and next live mission instead of rerunning the session.
21. If the continuation decision is `manual-review-required` or `blocked-no-mission-context`, stop and inspect the detailed helper artifacts instead of forcing salvage or rerun.
22. Run `scripts\build_latest_session_outcome_dossier.ps1 -PairRoot <pair-root>` later only when you intentionally need a narrower rebuild outside the supported salvage path.
23. Run `scripts\evaluate_latest_session_mission.ps1 -PairRoot <pair-root>` later only when you intentionally need to rebuild mission-closeout after a narrower artifact refresh.
24. Read `next_live_plan` when you need the full promotion-gap math, and read `next_live_session_mission` when you need the exact pre-run target and stop condition.
25. If the dossier, mission-attainment closeout, recovery assessment, or continuation controller says manual review is needed, run `powershell -NoProfile -File .\scripts\review_counted_pair_evidence.ps1 -PairRoot <pair-root>` before another live conservative attempt.
26. In that counted-pair review, trust authoritative evidence first: `pair_summary.json`, lane `summary.json`, raw patch histories, mission snapshot/execution, control/treatment/phase gate outputs, saved monitor state/history, and `grounded_evidence_certificate.json`.
27. Treat `mission_attainment.json`, wrapped milestone reports, and older markdown summaries as potentially stale narrative outputs unless they agree with the authoritative layer.
28. If the review says the pair remains counted, keep the promotion state and refresh only safe derived artifacts. If it recommends registry correction, stop and reconcile that explicitly before another live run.
29. If the counted status stays true but exact treatment-side or monitor-derived metrics still disagree, run `powershell -NoProfile -File .\scripts\reconcile_pair_metrics.ps1 -PairRoot <pair-root> -DryRun`.
30. Read `pair_metric_reconciliation.json` / `.md` as the canonical metric diff: it should show which sources were treated as canonical, which were secondary, which fields disagreed, and whether a safe refresh is allowed.
31. Use `-ExecuteRefresh` only when the reconciliation helper says the refresh is safe and auditable. That path is for secondary artifacts only; it must not silently rewrite the append-only registry or promotion history.
32. If the canonical metrics now agree and only wrapper narratives remain stale, run `powershell -NoProfile -File .\scripts\refresh_pair_wrapper_narratives.ps1 -PairRoot <pair-root>`.
33. Read `wrapper_refresh_report.json` / `.md` to confirm which wrapper files were regenerated from canonical sources and which promotion/gate fields were intentionally left unchanged.
34. Read `counted_pair_clearance.json` / `.md` to see whether the pair-level manual-review label can now be cleared. That clearance is separate from registry correction and must not be treated as a promotion-state rewrite by itself.
35. If the pair-level label clears but the global responsive gate or next-live objective still looks stale, run `powershell -NoProfile -File .\scripts\recompute_after_pair_clearance.ps1 -PairRoot <pair-root>`.
36. Read `post_clearance_recompute.json` / `.md` for the authoritative before-vs-after diff on the gate, next objective, grounded conservative counts, too-quiet counts, and strong-signal counts.
37. Treat the recompute as additive and conservative: it may prove the stale-looking manual-review state was actually still correct, and it still must not rewrite append-only registry history.
38. If you still need one explicit explanation of why the global state remains `manual-review-needed`, run `powershell -NoProfile -File .\scripts\review_grounded_evidence_matrix.ps1`.
39. Read `grounded_evidence_matrix.json` / `.md` for one row per counted grounded conservative session, including whether each row is appropriately conservative, too quiet, strong-signal, or merely tuning-usable.
40. Read `promotion_state_review.json` / `.md` for the global explanation of whether the current responsive gate and next-live objective are actually consistent with that matrix.
41. If the matrix confirms a genuinely mixed grounded conservative state and zero counted grounded strong-signal conservative sessions, run `powershell -NoProfile -File .\scripts\prepare_strong_signal_conservative_mission.ps1`.
42. Read `strong_signal_conservative_mission.json` / `.md` before another live spend. That mission keeps the treatment profile conservative, raises the evidence targets above the grounded minimum, and explains how the next run could disambiguate "appropriately conservative" vs "too quiet".
43. Prefer `powershell -NoProfile -File .\scripts\run_strong_signal_conservative_attempt.ps1` when you want that stronger-signal mission spent through the existing client-assisted conservative path and summarized into one pair-local attempt report.
44. Use `run_current_live_mission.ps1 -MissionPath <strong-signal-mission>` only when you intentionally want the lower-level mission runner without the strong-signal attempt wrapper.
45. Do not treat the strong-signal mission or the strong-signal attempt wrapper as responsive readiness by itself; a successful run only matters if the saved pair actually counts and adds grounded strong-signal conservative evidence.
46. If the local client launched but the saved pair still shows `0` human snapshots / `0` human presence seconds, stop and run `powershell -NoProfile -File .\scripts\audit_client_presence.ps1 -PairRoot <pair-root>` before another live attempt.
47. Read `client_presence_audit.json` / `.md` as a chain diagnosis rather than a scorecard: launch, server connect, lane attribution, human snapshot accumulation, and final pair-summary reflection.
48. Treat `lane-attribution-present-but-no-human-snapshots` as a very specific break: the lane-local HLDS log saw the client connect, but telemetry and summaries never counted that client as an in-game human participant.
49. Treat `client-launched-but-no-server-connect` differently: that means the launch path worked, but the server never logged a real connection at all.
50. When the audit still points at the join-completion boundary, run `powershell -NoProfile -File .\scripts\run_client_join_completion_probe.ps1` before another full strong-signal conservative session.
51. Read `client_join_completion_probe.json` / `.md` as the bounded control-lane answer to whether the chain reached `entered-the-game-seen`, `first-human-snapshot-seen`, `human-presence-accumulating`, and `control-lane-human-usable`.
52. Treat `connected-but-not-entered-game` as a launch/join completion problem, not as a tuning or certification problem.
53. Treat `entered-game-but-no-human-snapshot` as a telemetry-ingestion problem: the client got in, but saved control-lane evidence still never counted a human.
54. Treat `human-snapshot-seen-but-presence-does-not-accumulate` as a narrower accumulation problem: the first saved human snapshot appeared, but the saved presence window still stayed too weak.
55. Only return to another full strong-signal conservative attempt after the audit or bounded probe identifies a trustworthy entered-the-game to first-human-snapshot path and human presence starts accumulating in saved control-lane evidence.
56. When one bounded probe succeeds but another still fails earlier in the chain, run `powershell -NoProfile -File .\scripts\run_client_join_reliability_matrix.ps1 -Attempts 3 -UseLatestMissionContext`.
57. Read `client_join_reliability_matrix.json` / `.md` for the per-attempt matrix: launched process, server connection, entered-the-game, first human snapshot, human presence accumulation, final attempt verdict, and the exact break point when an attempt fails.
58. Read `client_join_reliability_certificate.json` / `.md` as the one-line spend decision: `not-ready-repeat-join-hardening`, `partially-reliable-repeat-bounded-probes`, or `ready-for-next-strong-signal-attempt`.
59. If the repeated matrix still fails before join is even attempted, run `powershell -NoProfile -File .\scripts\audit_probe_lane_startup.ps1 -ProbeRoot <failed-probe-root>`.
60. Read `probe_lane_startup_audit.json` / `.md` as the narrow startup/materialization answer: lane launch attempted, lane root materialized, port ready, join helper invoked, and the exact saved stderr/stdout paths that support that answer.
61. Treat `lane-launch-attempted-no-root` as a startup/materialization failure, not as a later join or telemetry problem. If the audit also reports a missing `Resolve-Path` lane root and a very long expected path, assume path-depth startup failure first.
62. Treat `lane-root-created-no-port-ready` as a later startup readiness problem: the lane capture root exists, but the control lane never became ready on the target port.
63. Treat `port-ready-no-join-invocation` as a join orchestration problem: startup cleared, but the join helper still was not called.
64. When a repeated probe already reached `entered-the-game-seen`, but the first saved human snapshot still appears missing, run `powershell -NoProfile -File .\scripts\audit_first_human_snapshot_boundary.ps1 -ProbeRoot <failed-probe-root>`.
65. Read `first_human_snapshot_audit.json` / `.md` as the later-boundary answer: authoritative HLDS join lines, saved telemetry history, lane summary reflection, and whether the first counted human snapshot was lost in enumeration, human classification, persisted telemetry, or summary aggregation.
66. Treat `snapshot-written-but-summary-not-updated` as a summary-aggregation failure, not as a missing join. That verdict means the first human snapshot already exists in `telemetry_history.ndjson`, but the summary/session layer still failed to reflect it.
67. Treat `first-human-snapshot-seen` as progress, not final readiness. The boundary cleared enough to reflect the first counted human snapshot, but accumulated saved human presence may still be too thin.
68. Treat `human-presence-accumulating` as the sign that the later summary layer is no longer the blocker and the path is ready for the stricter reliability judgment.
69. Treat `partially-reliable` as a real improvement, not as readiness. The current readiness policy is intentionally strict: every repeated bounded attempt in the suite must reach entered-the-game, first human snapshot, accumulating saved human presence, and control-lane human-usable without overrunning the matrix budget before another full strong-signal conservative session is justified.

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
2. `mission_attainment.md`
3. `guided_session\final_session_docket.md`
4. `scorecard.md`
5. `pair_summary.md`
6. `comparison.md`
7. treatment `summary.md` or `session_pack.md` if the treatment lane looks too quiet
8. control `summary.md` if the control lane looks weak or sparse

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
- `scripts\evaluate_latest_session_mission.ps1` writes `mission_attainment.json` and `mission_attainment.md` for the latest pair or a specific `-PairRoot`
- `scripts\prepare_next_live_session_mission.ps1` writes `next_live_session_mission.json` and `next_live_session_mission.md` for the very next live run
- `scripts\run_current_live_mission.ps1` launches that mission directly, writes `mission_execution.json` / `.md`, and blocks or records drift before the pair starts
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

## Mission Attainment

- run `powershell -NoProfile -File .\scripts\evaluate_latest_session_mission.ps1` after the session or target a specific pair with `-PairRoot`
- the helper writes `mission_attainment.json` and `mission_attainment.md` into the pair root
- it also reads `guided_session\mission_execution.json` when present, so a mission-divergent launch cannot be reported as mission-perfect later
- it is different from the mission brief: the mission brief is pre-run and says what the session must prove, while mission attainment is post-run and says whether that exact saved target was achieved
- it is different from the live monitor: the live monitor is the in-run stop/keep-running signal, while mission attainment is the post-run target-vs-actual closeout against the final evidence stack
- it is different from the outcome dossier: the dossier is the broader post-run consolidation artifact, while mission attainment is the narrower mission-closeout artifact tied to the saved mission snapshot
- `mission-divergent-run` means the operator explicitly launched something other than the saved mission, so the captured evidence must not be treated as a mission-perfect run
- read the `target_results` block literally: `target_value`, `actual_value`, `met`, and `explanation`
- `mission-met-but-no-promotion-impact` means the session can be operationally complete while still failing to change the real promotion ledger
- `mission-met-and-gap-reduced` means the session counted as grounded evidence and shrank a real promotion-gap component without changing the next objective
- `mission-met-and-next-objective-advanced` means the session counted as grounded evidence and changed the next objective, responsive gate, or both
- rehearsal, synthetic, no-human, weak-signal, insufficient-data, and otherwise non-grounded sessions must still fail mission attainment in the promotion sense; the next live mission remains conservative when that happens

## Session Recovery Assessment

- run `powershell -NoProfile -File .\scripts\assess_latest_session_recovery.ps1` after any interrupted, partial, or suspicious session, or target a specific pair with `-PairRoot`
- the helper writes `session_recovery_report.json` and `session_recovery_report.md` into the assessed pair root
- it decides whether the session is complete, interrupted before sufficiency, interrupted after sufficiency, partially recoverable, nonrecoverable, or manual-review-only
- when the session is recoverable, it also gives the exact `finalize_interrupted_session.ps1` command that matches the supported salvage path
- it is different from mission attainment: mission attainment answers whether the run met the mission, while recovery assessment answers whether the run finished cleanly enough to trust, salvage, or rerun
- it is different from the outcome dossier: the dossier is the completed-session consolidation layer, while recovery assessment is the interruption/recovery layer used before trusting that closeout
- if the helper says `run-post-pipeline-only` or `rebuild-dossier-and-closeout`, the session may still be usable without replaying the live human time
- if it says `rerun-current-mission` or `rerun-current-mission-with-new-pair-root`, keep the interrupted pair excluded from promotion logic and spend the next session on a clean rerun instead
- rehearsal, synthetic, workflow-validation-only, and other non-grounded sessions can still be structurally complete; the helper must say so without pretending they belong in responsive-promotion evidence

## Session Salvage

- run `powershell -NoProfile -File .\scripts\finalize_interrupted_session.ps1 -PairRoot <pair-root>` only after recovery assessment says the pair is recoverable
- the helper writes `session_salvage_report.json` and `session_salvage_report.md` into the pair root
- it can salvage recoverable post-pipeline failures without replaying the live session, but it refuses pre-sufficiency, nonrecoverable, and manual-review-only branches
- it is different from rerunning the mission: salvage preserves the saved pair and finishes the closeout stack around that exact evidence, while rerun creates a new pair root from a new live attempt
- a salvaged rehearsal, synthetic, weak-signal, or otherwise non-grounded session may still stay workflow-validation-only or excluded from promotion; that is expected and honest

## Mission Continuation Controller

- run `powershell -NoProfile -File .\scripts\continue_current_live_mission.ps1 -PairRoot <pair-root> -DryRun` after an interrupted, suspicious, or partially closed-out session when you want one supported next-step decision
- the helper writes `mission_continuation_decision.json` and `mission_continuation_decision.md` into the assessed pair root
- it stays preview-first by default; add `-Execute` only when you want it to actually call salvage or start a rerun
- it is the thin top-level layer above recovery and salvage: it reuses `assess_latest_session_recovery.ps1`, `finalize_interrupted_session.ps1`, and `run_current_live_mission.ps1` instead of replacing them
- it can decide `session-already-complete-no-action`, `session-already-complete-review-only`, `salvage-interrupted-session`, `rerun-current-mission`, `rerun-current-mission-with-new-pair-root`, `manual-review-required`, or `blocked-no-mission-context`
- if the session is complete but non-grounded, rehearsal-only, or workflow-validation-only, the helper still says no replay is needed while keeping the session excluded from promotion
- if rerun is required, the helper reuses the saved mission snapshot when available and otherwise falls back to the current mission brief only when that fallback is explicit and auditable
- it is different from recovery assessment: recovery classifies the session, while the continuation controller chooses and optionally executes the supported next action
- it is different from salvage: salvage only finalizes recoverable sessions, while the continuation controller can also say no-action, rerun, or manual review

## Continuation Rehearsal

- run `powershell -NoProfile -File .\scripts\run_mission_continuation_rehearsal.ps1` before trusting the first real human-rich conservative failure path
- the runner starts from the current mission-driven launcher, stages a controlled failure branch, runs recovery assessment, runs the continuation controller, and then writes branch-level `continuation_rehearsal_report.json` / `.md` plus a suite summary
- use `scripts\inject_pair_session_failure.ps1` only on rehearsal or other validation-only pair roots when you need to stage one branch manually
- the key rehearsal branches are:
  - `already-complete`: the controller should choose no action
  - `after-sufficiency-before-closeout` or `during-post-pipeline`: the controller should choose salvage
  - `before-sufficiency`: the controller should choose rerun
  - `missing-mission-snapshot`: the controller should stop for manual review
- rehearsal success means the branch verdict, continuation decision, salvage or rerun behavior, and final artifact stack all match the injected failure mode
- rehearsal success does not count as grounded live evidence. Salvaged or rerun rehearsal branches must still remain `rehearsal`, `synthetic`, `validation only`, excluded from promotion, and unable to unlock the responsive gate
- the rehearsal-safe registry must stay under the branch-local outputs such as `guided_session\registry\`; if rehearsal output starts pointing back at the real ledger, stop and fix that before another run
- use a completed rehearsal base pair with `-BasePairRoot` when you want to cover multiple failure modes without spending another rehearsal launch

## Recovery Readiness Matrix

- run `powershell -NoProfile -File .\scripts\run_recovery_branch_matrix.ps1` when you want one consolidated operator verdict on whether the recovery and continuation workflow is ready for the first real human-rich conservative session
- the helper writes `recovery_branch_matrix.json` / `.md` plus `recovery_readiness_certificate.json` / `.md`
- the matrix must cover `already-complete`, `after-sufficiency-before-closeout`, `during-post-pipeline`, `partial-artifacts-recoverable`, `before-sufficiency`, and `missing-mission-snapshot`
- read `recovery_readiness_certificate.md` first. If it says `ready-for-first-grounded-conservative-session`, the recovery policy is operationally validated from a failure-handling standpoint
- if it says `ready-with-known-gaps` or `blocked`, stop and inspect `recovery_branch_matrix.md` before spending the next real human-rich session
- a ready certificate does not count as grounded tuning evidence. It only says the continuation controller, salvage path, rerun path, and promotion-safety barriers behaved correctly in rehearsal
- the certificate must confirm that rehearsal evidence stayed excluded from promotion, salvaged rehearsal branches did not pollute the live registry, and the responsive gate stayed closed on rehearsal-only evidence

## First Grounded Conservative Attempt

- run `powershell -NoProfile -File .\scripts\run_first_grounded_conservative_attempt.ps1` when you are ready to attempt the first real grounded conservative control+treatment pack
- the helper launches the current mission in conservative mode, reuses the normal live monitor and post-run stack, and writes `first_grounded_conservative_attempt.json` / `.md`
- read that attempt report first after the run when the question is "did we get the first grounded conservative pack, did it count, and what changed?"
- if the attempt stayed non-grounded, the report must explain why directly instead of implying success
- if the attempt interrupted, the helper may use the supported continuation controller and salvage path automatically; do not invent a manual post-run workaround first
- if there is still no real human signal in the environment, the helper should end with an honest non-grounded verdict and keep `responsive` closed
- if you shorten timing or skip environment-prep steps for validation only, pass `-AllowMissionOverride` explicitly and treat the result as orchestration validation rather than the real milestone attempt

## Client-Assisted Grounded Conservative Attempt

- run `powershell -NoProfile -File .\scripts\run_human_participation_conservative_attempt.ps1` when this machine can launch `hl.exe` and you want the helper to turn that into a real control-then-treatment participation attempt
- it reuses `discover_hldm_client.ps1`, `join_live_pair_lane.ps1`, and `run_first_grounded_conservative_attempt.ps1` instead of creating a new mission or closeout path
- it launches the control lane first, then the treatment lane second, and writes `human_participation_conservative_attempt.json` / `.md`
- on the sequential auto-join path it now runs both the control-first switch gate and the treatment-hold gate, so the helper will not leave control early or leave treatment before grounded patch evidence is real
- the report records whether control join was attempted, whether treatment join was attempted, whether saved lane evidence actually showed human presence in each lane, and which grounded criteria were still missing
- it must not treat `hl.exe` launch alone as grounded evidence; if the pair still misses human thresholds, treatment patch-while-human-present, or post-patch observation, the report must say so directly

## Control-First Switch Gate

- run `powershell -NoProfile -File .\scripts\guide_control_to_treatment_switch.ps1 -PairRoot <pair-root> -Once` when you want an explicit answer about whether control is safe to leave yet
- run `powershell -NoProfile -File .\scripts\guide_control_to_treatment_switch.ps1 -UseLatest` when you want the helper to keep watching the newest pair interactively
- it differs from `monitor_live_pair_session.ps1`: the broader live monitor answers whether the whole pair is sufficient, while this helper answers whether the control-to-treatment handoff is justified yet
- if the control lane is still the blocker, the helper says exactly how many control snapshots and seconds are still missing
- if the pair already timed out non-grounded, the helper says that directly instead of pretending the operator can still rescue the same control handoff

## Treatment-Hold Patch Window Gate

- run `powershell -NoProfile -File .\scripts\guide_treatment_patch_window.ps1 -PairRoot <pair-root> -Once` when you want an explicit answer about whether treatment is safe to leave yet
- run `powershell -NoProfile -File .\scripts\guide_treatment_patch_window.ps1 -UseLatest` when you want the helper to keep watching the newest pair interactively
- it differs from `monitor_live_pair_session.ps1`: the broader live monitor answers whether the whole pair is sufficient, while this helper answers whether treatment itself has the grounded patch evidence and post-patch window yet
- if treatment is still the blocker, the helper says exactly how many counted patch-while-human-present events or post-patch seconds are still missing
- if the pair already timed out non-grounded, the helper says that directly and records whether a patch was merely applied during the human window from a pre-human recommendation

## Next Grounded Conservative Cycle

- run `powershell -NoProfile -File .\scripts\run_next_grounded_conservative_cycle.ps1` after the first grounded conservative capture already exists
- it reuses the client-assisted conservative attempt path and writes `grounded_conservative_cycle_report.json` / `.md`
- because the client-assisted helper now uses both the control-first gate and the treatment-hold gate on the sequential auto-join path, this cycle helper inherits the same control-before-treatment and treatment-before-exit discipline automatically
- `second-grounded-conservative-capture` means the latest live run counted toward promotion and moved grounded conservative sessions from `1` to `2`
- `conservative-gap-reduced-but-objective-unchanged` means the run counted and reduced the gap, but the planner still points at the same next objective afterward
- `conservative-objective-advanced` means the run counted and the next objective moved beyond `collect-more-grounded-conservative-sessions`
- responsive still stays closed unless the existing gate evaluation actually changes

## Local Client Discovery And Lane Join

- run `powershell -NoProfile -File .\scripts\discover_hldm_client.ps1` before the session when you need an explicit answer about whether automatic local lane joining is available
- `client-found-and-launchable` means the local client helper can be used directly; `client-not-found` means automatic launch is unavailable and preflight should stay `ready-with-warnings`
- run `powershell -NoProfile -File .\scripts\join_live_pair_lane.ps1 -Lane Control -UseLatest -DryRun` to preview the control lane target without launching
- run `powershell -NoProfile -File .\scripts\join_live_pair_lane.ps1 -Lane Treatment -PairRoot <pair-root> -DryRun` to preview the treatment lane target for a specific pair
- the pair runner now writes the helper commands into `control_join_instructions.txt`, `treatment_join_instructions.txt`, and `pair_join_instructions.txt`
- if automatic local launch is unavailable, proceed manually with the printed loopback or LAN `connect` command instead of pretending the machine is fully join-ready
- when you want the supported sequential control-then-treatment path on top of the first grounded conservative wrapper, run `powershell -NoProfile -File .\scripts\run_human_participation_conservative_attempt.ps1`
- when launch succeeded but saved human signal still stayed at zero, run `powershell -NoProfile -File .\scripts\run_client_join_completion_probe.ps1` before another full live conservative session
- `connected-but-not-entered-game` means the server saw the connection, but the saved control-lane evidence still has no trusted in-game join state
- `entered-game-but-no-human-snapshot` means the join completed, but saved control-lane telemetry still never counted a human player
- when the server log and telemetry history disagree with the saved summary/session layer, run `powershell -NoProfile -File .\scripts\audit_first_human_snapshot_boundary.ps1 -ProbeRoot <probe-root>`
- `snapshot-written-but-summary-not-updated` means the first human snapshot is already present in `telemetry_history.ndjson`, but the saved lane summary/session pack still failed to reflect it
- the system is only ready for another full strong-signal conservative session after the bounded probe shows `entered-the-game-seen` or equivalent, at least one counted human snapshot, and accumulating saved human presence
- when one bounded probe succeeds but reliability still looks mixed, run `powershell -NoProfile -File .\scripts\run_client_join_reliability_matrix.ps1 -Attempts 3 -UseLatestMissionContext`
- `partially-reliable-repeat-bounded-probes` means the repaired path is improving but still too mixed for another full strong-signal spend
- `ready-for-next-strong-signal-attempt` means the repeated bounded probe suite cleared the join path end to end on every attempt under the current conservative policy

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

## Mission Brief

- `scripts\prepare_next_live_session_mission.ps1` is the pre-run operator brief for the very next live session
- it writes `next_live_session_mission.json` and `next_live_session_mission.md` under `lab\logs\eval\registry\`
- it now also carries launcher defaults that `scripts\run_current_live_mission.ps1` uses for drift comparison
- it reads the current responsive gate, the current next-live planner output, and the latest available live outcome dossier when one exists
- it is narrower than the planner: the planner explains the full gap, while the mission brief says what exact thresholds to hit, what exact stop condition to watch, what exact failure conditions still make the run non-grounded, and whether the session can reduce or fully close any part of the gap
- it is different from the outcome dossier: the dossier explains what the last session changed after the run, while the mission brief explains what the next session must accomplish before the run
- it remains conservative until grounded evidence exists, even if rehearsal or non-grounded live evidence looked promising
- it uses the same live-monitor sufficiency bar instead of inventing a second stop rule, so the mission and the live monitor stay aligned

## Mission-Driven Launch

- `scripts\run_current_live_mission.ps1` reads the current mission brief by default and launches the existing guided workflow from that mission instead of asking the operator to retype the parameters
- use `-DryRun` or `-PrintCommandOnly` to inspect the mission path, launch parameters, exact guided-runner command, and drift verdict without starting a session
- output-root drift is allowed by default because it is operational only; safe port drift requires `-AllowSafePortOverride`
- changing map, bot count, bot skill, treatment profile, or weakening the human-signal or post-patch thresholds is blocked unless `-AllowMissionOverride` is supplied
- while the responsive gate is still closed, switching the mission from `conservative` to `responsive` is blocked by default; even with `-AllowMissionOverride`, the launch stays mission-divergent and later mission-attainment will say so explicitly

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
