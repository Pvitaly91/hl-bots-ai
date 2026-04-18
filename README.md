# hl-bots-ai

PROMPT_ID_BEGIN
HLDM-JKBOTTI-AI-STAND-20260415-30
PROMPT_ID_END

`hl-bots-ai` is a Windows-first Half-Life Deathmatch bot lab built on top of the upstream [Bots-United/jk_botti](https://github.com/Bots-United/jk_botti) codebase. The repository keeps the original jk_botti source layout in the repo root, adds a Visual Studio 2022 Win32 build, and layers in a slow AI balance director that adjusts only high-level bot tuning through a file bridge.

The lab is designed to keep working offline. If no `OPENAI_API_KEY` is present, the Python sidecar uses a deterministic rules engine. If the sidecar is absent or errors, the server and bot plugin still run.

## What This Repo Contains

- Upstream `jk_botti` source imported into the repository root with upstream attribution preserved.
- `hl-bots-ai.sln` and `jk_botti_mm.vcxproj` for Visual Studio 2022 `Win32|Debug` and `Win32|Release`.
- `ai_balance.cpp` and related hooks in the plugin for telemetry export and bounded patch application.
- `ai_director/` Python sidecar for offline fallback rules, evaluation helpers, and optional OpenAI Responses API usage.
- `ai_director/tuning.py`, `ai_director/testdata/`, and replay sweep tooling for deterministic profile comparison.
- `scripts/` PowerShell automation for setup, build, launch, smoke testing, and evaluation capture on Windows.
- `scripts/run_balance_eval.ps1`, `scripts/run_mixed_balance_eval.ps1`, `scripts/run_balance_parameter_sweep.ps1`, and `scripts/summarize_balance_eval.ps1` for control/treatment capture and replay-driven profile comparison.
- `scripts/monitor_live_pair_session.ps1` and `scripts/monitor_live_pair_session.bat` for live evidence-sufficiency monitoring during an active control+treatment pair session.
- `scripts/run_guided_live_pair_session.ps1` and `scripts/run_guided_live_pair_session.bat` for the single conservative-first live operator workflow that runs preflight, the paired capture, optional monitor-driven auto-stop, the full post-session pipeline, and a final session docket.
- `scripts/plan_next_live_session.ps1` and `scripts/plan_next_live_session.bat` for explicit promotion-gap accounting that says what certified grounded evidence is still missing before responsive can open and what the next conservative live session should try to prove.
- `scripts/analyze_latest_grounded_session.ps1` and `scripts/analyze_latest_grounded_session.bat` for the post-session delta layer that compares the registry state with and without the latest pair counted and explains exactly what changed.
- `scripts/run_guided_pair_rehearsal.ps1` for deterministic guided-workflow sufficiency rehearsal that drives the existing live monitor semantics without spending a real human-rich session.
- `scripts/certify_latest_pair_session.ps1` and `scripts/certify_latest_pair_session.bat` for strict grounded-evidence certification of the latest pair pack or a specified pair root.
- `scripts/run_shadow_profile_review.ps1` plus `ai_director/tools/replay_captured_lane_with_profiles.py` for offline counterfactual review of a captured treatment lane.
- `ai_director/testdata/pair_sessions/`, `scripts/generate_pair_session_fixtures.py`, and `scripts/run_fixture_decision_demo.ps1` for synthetic post-run decision validation.
- `docs/test-stand.md` with local HLDS lab details.
- `docs/operator-checklist.md` with the first real human pair-session operator flow.
- `docs/first-live-pair-notes-template.md` as an optional lightweight note sheet for the first real human pair session.
- `AGENTS.md` for future repository automation guidance.

## Architecture Overview

The lab has two cooperating parts:

1. The Metamod plugin (`jk_botti_mm.dll`) runs inside HLDS and writes telemetry snapshots to `valve/addons/jk_botti/runtime/ai_balance/telemetry.json`.
2. The Python sidecar reads telemetry, computes a bounded balance patch, and writes `patch.json` back atomically.

The plugin only reads compact, high-level patch values:

- `target_skill_level` in the safe `1..5` jk_botti range.
- `bot_count_delta` limited to `-1`, `0`, or `1`.
- `pause_frequency_scale` clamped to `0.85..1.15`.
- `battle_strafe_scale` clamped to `0.85..1.15`.

The plugin applies these changes slowly:

- at most one skill-level step per apply cycle,
- at most one bot add or remove per apply cycle,
- cooldown-gated application with log output,
- no direct per-frame model calls to OpenAI,
- no hidden information, impossible reactions, wallhack logic, or aim cheating.

## Repository Layout

- Repo root: upstream jk_botti source tree and original build files.
- `ai_director/`: Python sidecar, prompt, env example, and tests.
- `scripts/`: PowerShell setup and launch scripts for the Windows lab.
- `docs/`: operator documentation for the local test stand.
- `addons/jk_botti/runtime/ai_balance/`: runtime bridge folder template kept in git with `.gitkeep`.
- `build/`: staged VS2022 output, ignored from git.
- `lab/`: local HLDS/SteamCMD/test assets, ignored from git.

## Prerequisites

- Windows with Visual Studio 2022 or VS Build Tools 2022 and MSBuild.
- Python 3.11+.
- PowerShell 5.1+ or PowerShell 7+.
- Internet access only for optional dependencies:
  - SteamCMD and HLDS install/update,
  - Metamod-P download,
  - OpenAI API usage.

Game files, Metamod archives, SteamCMD payloads, generated waypoints, and compiled binaries are intentionally not committed.

## Quick Start

The current AI launcher remains unchanged:

```bat
scripts\run_test_stand_with_bots.bat
```

The new no-AI baseline launcher for standard jk_botti crossfire testing is:

```bat
scripts\run_standard_bots_crossfire.bat
```

Legacy positional examples:

```bat
scripts\run_test_stand_with_bots.bat
scripts\run_test_stand_with_bots.bat crossfire
scripts\run_test_stand_with_bots.bat stalkyard 6
scripts\run_test_stand_with_bots.bat stalkyard 6 2
```

```bat
scripts\run_standard_bots_crossfire.bat
scripts\run_standard_bots_crossfire.bat crossfire
scripts\run_standard_bots_crossfire.bat crossfire 6
scripts\run_standard_bots_crossfire.bat crossfire 6 2
```

The `.bat` wrappers also accept direct PowerShell-style passthrough arguments, which is the fastest way to iterate once SteamCMD and Metamod are already in place:

```bat
scripts\run_standard_bots_crossfire.bat -Map crossfire -BotCount 4 -BotSkill 3 -Port 27016 -SkipSteamCmdUpdate -SkipMetamodDownload
scripts\run_test_stand_with_bots.bat -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -SkipSteamCmdUpdate -SkipMetamodDownload
scripts\run_control_treatment_pair.bat -Map crossfire -BotCount 4 -BotSkill 3 -ControlPort 27016 -TreatmentPort 27017 -SkipSteamCmdUpdate -SkipMetamodDownload
```

The AI launcher builds the Win32 DLL, prepares `.\lab`, starts the AI director, generates `lab\hlds\valve\addons\jk_botti\jk_botti_<map>.cfg` from `addons\jk_botti\test_bots.cfg`, and then starts HLDS with the requested bot count and skill. If `OPENAI_API_KEY` is absent, the launcher stays in deterministic offline fallback mode.

The no-AI launcher automates the existing manual baseline path for standard jk_botti testing on `crossfire`: it builds `Release|Win32`, prepares the default `.\lab` test stand, writes a deterministic `jk_botti_<map>.cfg` with `jk_ai_balance_enabled 0`, does not start `scripts\run_ai_director.ps1`, and then starts HLDS with logs under `lab\logs`.

Build the Win32 plugin DLL:

```powershell
powershell -NoProfile -File .\scripts\build_vs2022.ps1 -Configuration Release -Platform Win32
```

Prepare a local HLDM lab under `.\lab`:

```powershell
powershell -NoProfile -File .\scripts\setup_test_stand.ps1
```

Run the sidecar and HLDS together:

```powershell
powershell -NoProfile -File .\scripts\run_lab.ps1
```

Run the smoke test after the lab is up:

```powershell
powershell -NoProfile -File .\scripts\smoke_test.ps1
```

For the no-AI attach baseline on `crossfire`, use:

```powershell
powershell -NoProfile -File .\scripts\smoke_test.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -Mode NoAI
```

## Fast Local Iteration

Use the no-AI baseline first when the goal is fast attach/debug repetition:

```bat
scripts\run_standard_bots_crossfire.bat -Map crossfire -BotCount 4 -BotSkill 3 -Port 27016 -SkipSteamCmdUpdate -SkipMetamodDownload
```

This keeps the startup surface narrowed to `HLDS -> Metamod -> jk_botti_mm.dll`, preserves the standard `crossfire` baseline, writes logs under `lab\logs`, and leaves `jk_ai_balance_enabled 0` intentional in the generated config.

Use the AI launcher when you need sidecar, telemetry, and patch-path coverage:

```bat
scripts\run_test_stand_with_bots.bat -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -SkipSteamCmdUpdate -SkipMetamodDownload
```

Both wrappers remain backward-compatible with the old positional arguments, but if the first argument starts with `-` they pass all arguments directly through to the PowerShell implementation. The useful repeat-test knobs are `-Map`, `-BotCount`, `-BotSkill`, `-LabRoot`, `-Port`, `-SkipSteamCmdUpdate`, and `-SkipMetamodDownload`.

## Balance Evaluation Harness

Use the evaluation runner when the goal is behavior measurement instead of only attach validation:

```powershell
powershell -NoProfile -File .\scripts\run_balance_eval.ps1 -Mode NoAI -Map crossfire -BotCount 4 -BotSkill 3 -Port 27016 -DurationSeconds 50 -SkipSteamCmdUpdate -SkipMetamodDownload
powershell -NoProfile -File .\scripts\run_balance_eval.ps1 -Mode AI -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -DurationSeconds 80 -TuningProfile default -SkipSteamCmdUpdate -SkipMetamodDownload
powershell -NoProfile -File .\scripts\run_balance_eval.ps1 -Mode AI -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -DurationSeconds 80 -TuningProfile conservative -WaitForHumanJoin -HumanJoinGraceSeconds 120 -LaneLabel mixed-session-treatment -SkipSteamCmdUpdate -SkipMetamodDownload
powershell -NoProfile -File .\scripts\run_mixed_balance_eval.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -DurationSeconds 80 -TuningProfile conservative -WaitForHumanJoin -HumanJoinGraceSeconds 120 -LaneLabel mixed-session-treatment -SkipSteamCmdUpdate -SkipMetamodDownload
powershell -NoProfile -File .\scripts\run_control_treatment_pair.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -ControlPort 27016 -TreatmentPort 27017 -DurationSeconds 80 -WaitForHumanJoin -HumanJoinGraceSeconds 120 -TreatmentProfile conservative -SkipSteamCmdUpdate -SkipMetamodDownload
```

The no-AI lane remains the primary control:

- default map `crossfire`
- default bot count `4`
- default bot skill `3`
- `jk_ai_balance_enabled 0`
- no Python sidecar
- no patch emission or patch application

The AI lane reuses the existing sidecar-backed launcher and adds copied lane artifacts under `lab\logs\eval\<timestamp>-<mode>-...`.

The paired live-session runner is the recommended next human workflow:

- `scripts\run_control_treatment_pair.ps1` runs the no-AI control lane first, then the AI treatment lane, and packages both under `lab\logs\eval\pairs\<timestamp>-...`.
- the control lane now supports the same human-join-aware waiting thresholds as the treatment lane, while still staying sidecar-free with `jk_ai_balance_enabled 0`.
- the pair runner defaults the treatment lane to `conservative`, because it is the safest next live profile for collecting honest evidence before trying `responsive`.
- `scripts\monitor_live_pair_session.ps1` is the thin live observer for that pair root. It polls the current pair artifacts plus the active runtime history, writes `live_monitor_status.json` and `live_monitor_status.md`, and keeps the stop/keep-running decision conservative.
- `scripts\run_guided_live_pair_session.ps1` is the operator-facing wrapper over preflight, the pair runner, the live monitor, review, shadow review, scoring, registration, registry summary, responsive-trial gate, and the final session docket.
- `scripts\plan_next_live_session.ps1` is the read-only promotion-gap planner. It reuses the certified registry summary and responsive gate outputs to produce `next_live_plan.json` and `next_live_plan.md` with the exact deficits still blocking responsive and the concrete objective for the next live session.
- each paired run writes `pair_summary.json`, `pair_summary.md`, `comparison.json`, `comparison.md`, `control_join_instructions.txt`, `treatment_join_instructions.txt`, and the nested lane/session-pack folders.
- each guided paired run also writes `guided_session\final_session_docket.json` and `guided_session\final_session_docket.md` under the pair root so the operator has one concise end-of-run answer, including the current next-live planner objective and profile.
- `scripts\run_shadow_profile_review.ps1` can then replay the saved treatment lane through `conservative`, `default`, and `responsive` offline without spending another live human session.

`scripts\run_balance_eval.ps1` now separates plumbing health from tuning usability:

- `-LaneLabel` stamps a human-readable role such as `control-baseline` or `mixed-session-treatment`.
- `-TuningProfile` selects a named offline rule profile such as `conservative`, `default`, or `responsive`.
- `-WaitForHumanJoin` keeps either lane alive past the base duration until it becomes human-usable or the grace window expires. AI lanes still also require grounded treatment-response evidence before they count as tuning-usable.
- `-HumanJoinGraceSeconds`, `-MinHumanSnapshots`, and `-MinHumanPresenceSeconds` define the live mixed-session quality gate.
- `-MinPatchEventsForUsableLane` lets the runner wait a little longer for a bounded treatment response when meaningful human-vs-bot imbalance is already present.

If no humans join, the lane can still be `ai-healthy`, but the summary marks it explicitly as `ai-healthy-no-humans` instead of pretending it was ready for tuning. Sparse joins are called out as `ai-healthy-human-sparse`.

`scripts\run_mixed_balance_eval.ps1` is the thin workflow helper for real human-vs-bot sessions. It reuses the same evaluation runner, prints the join target up front, defaults the lane label to `mixed-session-treatment`, and writes a bounded session pack with:

- `lane.json`
- `summary.json`
- `summary.md`
- `session_pack.json`
- `session_pack.md`
- `join_instructions.txt`
- `human_presence_timeline.ndjson`
- copied HLDS, bootstrap, sidecar, bot-config, telemetry, and patch artifacts

Live lane summaries now also record the active tuning profile and the effective knobs used for that run, so mixed-session results can be interpreted relative to `conservative`, `default`, or `responsive` treatment behavior.

Read pair artifacts like this:

- `scorecard.json` / `scorecard.md`: concise operator-facing session scorecard and explicit next-action recommendation, written by `scripts\score_latest_pair_session.ps1`.
- `pair_summary.json` / `pair_summary.md`: the operator-facing verdict for the whole pair, including whether the run was only plumbing-valid, partially usable, tuning-usable, or strong-signal.
- `comparison.json` / `comparison.md`: grounded control-vs-treatment metrics such as both lane verdicts, both evidence-quality labels, whether treatment patched while humans were present, whether a post-patch observation window existed, frag-gap samples while humans were present, and a conservative explanation string.
- `control_join_instructions.txt` and `treatment_join_instructions.txt`: the exact join targets to hand to the human participant for each lane.

Interpret the operator note conservatively:

- `plumbing-valid only`: both launch paths worked, but the pair never captured enough human signal to justify tuning claims.
- `partially usable`: one lane was useful or treatment hinted at something interesting, but the pair is not yet fair enough to compare honestly.
- `tuning-usable`: both lanes were human-usable and treatment produced at least one grounded post-patch observation window.
- `strong-signal`: both lanes were human-usable and the treatment lane produced multiple grounded post-patch windows, which is enough to discuss stability or underactivity relative to control.

If `Half-Life\hl.exe` is available locally, `scripts\launch_local_hldm_client.ps1 -Port <port> -DryRun` resolves the client path and prints the launch command without starting the game. If the executable is missing, the helper fails with a precise prereq message instead of failing silently.

For the next real conservative human pair session, use the guided workflow first:

```powershell
powershell -NoProfile -File .\scripts\run_guided_live_pair_session.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -ControlPort 27016 -TreatmentPort 27017 -DurationSeconds 80 -WaitForHumanJoin -HumanJoinGraceSeconds 120 -TreatmentProfile conservative -SkipSteamCmdUpdate -SkipMetamodDownload
```

Rehearse the same guided workflow end to end without a real human participant like this:

```powershell
powershell -NoProfile -File .\scripts\run_guided_live_pair_session.ps1 -RehearsalMode -RehearsalFixtureId strong_signal_keep_conservative -RehearsalStepSeconds 2 -Map crossfire -BotCount 4 -BotSkill 3 -ControlPort 27016 -TreatmentPort 27017 -DurationSeconds 18 -WaitForHumanJoin -HumanJoinGraceSeconds 20 -MinHumanSnapshots 3 -MinHumanPresenceSeconds 60 -MinPatchEventsForUsableLane 2 -MinPostPatchObservationSeconds 20 -TreatmentProfile conservative -AutoStartMonitor -AutoStopWhenSufficient -MonitorPollSeconds 1 -RunPostPipeline
```

That rehearsal path validates only workflow behavior:

- the live monitor advances through the normal `waiting-*` verdicts
- the guided runner auto-stops only after `sufficient-for-tuning-usable-review`
- the pair pack finalizes to `sufficient-for-scorecard`
- the full post-run pipeline still runs and writes the final docket
- the saved evidence is marked `synthetic_fixture=true`, `rehearsal_mode=true`, `validation_only=true`, and `evidence_origin=rehearsal`
- the guided workflow writes the rehearsal registry under `guided_session\registry\` so real promotion ledgers stay untouched
- rehearsal success does not validate tuning quality and must never be treated as real human-rich promotion evidence

Use `-AutoStopWhenSufficient` only when you want the guided runner to request an early stop after the live monitor reaches `sufficient-for-tuning-usable-review` or `sufficient-for-scorecard`. It must not stop on the `waiting-*` states or on insufficient-data states.

Use manual stop instead when:

- you want an operator to decide based on the live feel of the session
- you want longer treatment observation even after the minimum grounded bar is met
- you are validating the no-human path and expect the session to finish honestly as insufficient-data

The guided workflow still stays thin:

- preflight remains `scripts\preflight_real_pair_session.ps1`
- paired capture remains `scripts\run_control_treatment_pair.ps1`
- monitoring remains `scripts\monitor_live_pair_session.ps1`
- post-run review remains `scripts\review_latest_pair_run.ps1`
- offline counterfactual review remains `scripts\run_shadow_profile_review.ps1`
- scoring remains `scripts\score_latest_pair_session.ps1`
- registration remains `scripts\register_pair_session_result.ps1`
- registry summary remains `scripts\summarize_pair_session_registry.ps1`
- next-live promotion-gap planning remains `scripts\plan_next_live_session.ps1`
- responsive promotion gating remains `scripts\evaluate_responsive_trial_gate.ps1`

Read the final guided docket like this:

- `final_session_docket.json`: machine-readable final state for the pair, monitor, post-run outputs, and operator recommendation flags
- `final_session_docket.md`: concise human-facing end-of-run answer that says whether the session was sufficient, whether conservative should stay live, and whether responsive must remain blocked

Interpret the live monitor conservatively:

- `waiting-for-control-human-signal`: control still lacks enough human snapshots or human-presence time, so the pair is not comparable yet.
- `waiting-for-treatment-human-signal`: control cleared the gate, but treatment still lacks enough grounded human presence.
- `waiting-for-treatment-patch-while-humans-present`: treatment humans were present long enough, but the AI has not yet produced enough live human-present patch events.
- `waiting-for-post-patch-observation-window`: treatment already patched while humans were present, but the post-patch observation time is still too short to stop honestly.
- `sufficient-for-tuning-usable-review`: the minimum honest stop bar is met during the live run. Both lanes cleared the human gate, treatment patched while humans were present, and there is already a meaningful post-patch observation window.
- `sufficient-for-scorecard`: the same grounded stop bar is met and the pair pack is already finalized, so the normal scorecard workflow can run immediately.
- `insufficient-data-timeout`: the pair ended before the evidence gate cleared. Treat it as insufficient data, not as live tuning proof.
- `blocked-no-active-pair-run`: the monitor could not find an active pair to observe.

`sufficient-for-tuning-usable-review` means the operator can stop the live session now without pretending the lane still needs more time to become grounded. `sufficient-for-scorecard` means the same evidence bar is already satisfied and the saved pair pack is ready for the post-run scorecard helper.

Preflight verdicts mean:

- `ready-for-human-pair-session`: required scripts, build output, ports, and profile selection are ready without current warnings.
- `ready-with-warnings`: the pair can be run, but at least one non-blocking prerequisite or optional helper still needs attention.
- `blocked`: do not spend a human session yet; fix the reported blockers first.

Use `docs\operator-checklist.md` as the concise runbook for the first real human pair session.
Use `docs\first-live-pair-notes-template.md` only if an operator wants a lightweight place to capture subjective notes next to the saved artifacts.

Run the scorecard helper after the review step:

```powershell
powershell -NoProfile -File .\scripts\score_latest_pair_session.ps1
```

Register the newest scored pair pack into the append-only ledger:

```powershell
powershell -NoProfile -File .\scripts\register_pair_session_result.ps1
powershell -NoProfile -File .\scripts\register_pair_session_result.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
powershell -NoProfile -File .\scripts\register_pair_session_result.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack> -NotesPath .\lab\logs\eval\pairs\<pair-pack>\session_notes.md
```

Certify whether the saved pair pack counts as real grounded promotion evidence:

```powershell
powershell -NoProfile -File .\scripts\certify_latest_pair_session.ps1
powershell -NoProfile -File .\scripts\certify_latest_pair_session.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
```

Summarize the accumulated pair-session ledger after registration:

```powershell
powershell -NoProfile -File .\scripts\summarize_pair_session_registry.ps1
```

Interpret the scorecard treatment assessment like this:

- `too quiet`: humans were present long enough to compare lanes, and conservative still looked too quiet relative to control under grounded live evidence.
- `appropriately conservative`: conservative produced grounded human-present patch evidence without looking oscillatory or overactive.
- `inconclusive`: human presence, patch timing, or post-patch observation windows were still too weak to justify a profile decision.
- `too reactive`: the treatment lane looked oscillatory or violated a guardrail, so artifacts need manual review before another live profile choice.

Use the scorecard recommendation conservatively:

- `keep-conservative-and-collect-more`: conservative already looks healthy enough to remain the live default.
- `treatment-evidence-promising-repeat-conservative`: there is promising live signal, but repeat conservative before considering a profile change.
- `weak-signal-repeat-session`: humans joined, but the post-patch evidence stayed weak; repeat conservative first.
- `conservative-looks-too-quiet-try-responsive-next`: only justified when humans were present long enough to compare lanes and conservative still stayed too quiet.
- `responsive-too-reactive-revert-to-conservative`: grounded responsive evidence already says the live treatment overreacted, so the next live profile should move back to conservative.
- `insufficient-data-repeat-session`: reject the session for tuning and collect another live pair first.
- `manual-review-needed`: inspect `comparison.md`, `scorecard.md`, and the treatment lane summary before choosing the next action.

## Shadow Profile Review

Run the shadow review helper after a captured pair when you want to know what `default` or `responsive` would have done against the same treatment-lane history:

```powershell
powershell -NoProfile -File .\scripts\run_shadow_profile_review.ps1 -UseLatest -Profiles conservative default responsive
powershell -NoProfile -File .\scripts\run_shadow_profile_review.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack> -RequireHumanSignal -MinHumanSnapshots 2 -MinHumanPresenceSeconds 40
```

The helper writes `shadow_profiles.json`, `shadow_profiles.md`, `shadow_recommendation.json`, and `shadow_recommendation.md` under `<pair-pack>\shadow_review\`.

Use it to answer:

- what the actual live conservative lane did
- what `default` would have done on the same captured telemetry
- what `responsive` would have done on the same captured telemetry
- whether responsive looks justified for the next live trial
- whether conservative still looks safest
- whether the captured evidence is still too weak to justify any profile change

Read the shadow recommendation conservatively:

- `keep-conservative`: the captured lane does not justify a live profile change yet.
- `conservative-and-default-similar`: shadow `default` stayed materially similar to the captured conservative lane, so changing the next live profile would spend human time without a grounded reason.
- `insufficient-data-no-promotion`: the captured lane never cleared the human-signal gate strongly enough for promotion; shadow replay is still plumbing or weak-signal support only.
- `conservative-looks-too-quiet-responsive-candidate`: conservative looks too quiet and responsive would have created more grounded human-present treatment evidence without tripping the guardrails. This is still weaker than another real human session.
- `responsive-would-have-overreacted`: responsive would have looked too reactive on the captured lane, so conservative should stay live.

Shadow review is useful before spending a real live session on `responsive` because it lets the operator ask a bounded "what if" question against the same saved lane instead of blindly committing a second human session to a riskier profile.

## Cross-Session Evidence Ledger

Use the registry layer to turn repeated live pair runs into one honest evidence history instead of treating each scorecard in isolation.

- `scripts\register_pair_session_result.ps1` reads the latest pair pack by default, or a specific `-PairRoot`, and appends one normalized entry into `lab\logs\eval\registry\pair_sessions.ndjson`.
- duplicate registration is blocked by default; the helper skips with a clear message instead of silently writing the same pair pack twice.
- registration also writes `grounded_evidence_certificate.json` and `grounded_evidence_certificate.md` into the pair root. `scripts\certify_latest_pair_session.ps1` can rerun the same certification later without mutating the append-only ledger.
- each registry entry records the pair ID/root, sortable run identity, map, bot count, bot skill, control/treatment lane labels, treatment profile, pair classification, lane verdicts, evidence quality, whether treatment patched while humans were present, whether a meaningful post-patch window existed, scorecard recommendation, treatment-behavior assessment, optional shadow-review recommendation fields when present, whether the session is tuning-usable, optional notes path, embedded prompt ID or commit SHA metadata, and grounded-evidence certification fields.
- notes are optional: either pass `-NotesPath` explicitly or place a notes file in the pair root. Missing notes never block registration.
- subjective notes are carried as context only; the promotion logic still keys off lane evidence, pair classification, and scorecard fields first.
- `scripts\summarize_pair_session_registry.ps1` writes `registry_summary.json`, `registry_summary.md`, `profile_recommendation.json`, and `profile_recommendation.md` under `lab\logs\eval\registry\`.
- `scripts\summarize_pair_session_registry.ps1 -EvaluateResponsiveTrialGate` can refresh the latest responsive-trial gate in the same pass.
- `scripts\summarize_pair_session_registry.ps1 -EvaluateNextLiveSessionPlan` can also refresh `next_live_plan.json` and `next_live_plan.md` after the registry summary is written.
- a pair counts toward promotion only when the certification helper says it is real grounded evidence: live origin, not rehearsal, not synthetic, minimum human-signal thresholds met in both lanes, treatment patched while humans were present, a meaningful post-patch observation window exists, and the pair clears `tuning-usable` or stronger.
- rehearsal, synthetic, no-human, plumbing-valid-only, comparison-insufficient-data, insufficient-data, and weak-signal sessions remain visible in the ledger but are excluded from promotion counts by reason.
- the registry summary reports total registered sessions, total certified grounded sessions, total non-certified sessions, workflow-validation-only sessions, excluded sessions by reason, sessions by pair classification, sessions by treatment profile, grounded counts for insufficient-data / weak-signal / tuning-usable / strong-signal evidence buckets, human-present patch counts, meaningful post-patch window counts, treatment-behavior assessment counts for `too quiet`, `appropriately conservative`, `inconclusive`, and `too reactive`, and how often shadow review suggested keep conservative, insufficient-data-no-promotion, responsive-candidate, or responsive-too-reactive.
- the profile recommendation stays intentionally conservative. It will not recommend `responsive` from non-certified sessions, and it requires repeated certified grounded conservative evidence before promotion.
- `keep-conservative` means the current live default is still behaving safely.
- `collect-more-conservative-evidence` means there is some usable signal, but not enough repeated grounded evidence yet to justify promotion.
- `conservative-validated-try-responsive` is only justified after repeated grounded conservative sessions show that conservative is consistently too quiet under real human presence.
- `responsive-too-reactive-revert-to-conservative` means grounded responsive evidence already shows overreaction and the live default should move back to conservative.
- `insufficient-data-repeat-session` and `weak-signal-repeat-session` mean the evidence is still too thin to justify any profile change.
- `manual-review-needed` means the cross-session evidence conflicts or a grounded guardrail concern needs an operator read before another live choice.

Conservative remains the default next live treatment profile until the ledger says otherwise. That keeps profile promotion bounded, reversible, and driven by accumulated evidence instead of one noisy session.

## Latest-Session Delta Analysis

Use `scripts\analyze_latest_grounded_session.ps1` after the normal post-run pipeline when the question is not only "what is the current gap?" but "what changed because of the latest pair?"

- it writes `grounded_session_analysis.json`, `grounded_session_analysis.md`, `promotion_gap_delta.json`, and `promotion_gap_delta.md`
- by default it analyzes the latest saved pair pack; pass `-PairRoot .\lab\logs\eval\pairs\<pair-pack>` when you want a specific live pair instead
- it reuses grounded-evidence certification, the pair-session registry shape, the registry summary, the responsive-trial gate, and the next-live planner instead of inventing a second source of truth
- it computes two scenario snapshots under `analysis_scenarios\without_latest\` and `analysis_scenarios\with_latest\`, then reports the exact delta between them
- `counts_toward_promotion = false` means the latest pair stayed visible but did not shrink the real responsive-promotion gap
- `reduced_promotion_gap = true` means at least one real responsive-opening deficit moved in the right direction, such as grounded conservative sessions, grounded conservative too-quiet sessions, or distinct grounded too-quiet pair IDs
- `grounded-conservative-too-quiet-evidence-added` means the latest grounded conservative session specifically added too-quiet evidence instead of only adding another generic grounded session
- `grounded-strong-signal-conservative-added` means the latest grounded conservative session improved the keep-conservative evidence record without necessarily moving the responsive-opening thresholds
- `responsive-blocker-added` means the latest grounded responsive session added too-reactive blocker evidence and therefore moved the project away from another responsive promotion
- `no-impact-non-grounded-session` is the honest answer for rehearsal, synthetic, no-human, weak-signal, plumbing-only, or otherwise excluded sessions. They remain auditable, but they must not fabricate a useful delta

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\analyze_latest_grounded_session.ps1
powershell -NoProfile -File .\scripts\analyze_latest_grounded_session.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
```

Read the outputs like this:

- `grounded_session_analysis.md` is the operator summary of the latest pair, grounded certification, before-vs-after counts, impact classification, and the exact next-step change or non-change
- `promotion_gap_delta.md` is the compact evidence-accounting view with the before/after/delta numbers for grounded sessions, grounded too-quiet counts, strong-signal counts, responsive blocker counts, gate state, and next objective
- if the latest session is rehearsal, synthetic, weak, or no-human, the correct result is often "still blocked in the same state"

## Next Live Session Planner

Use `scripts\plan_next_live_session.ps1` when the question is not only "is responsive blocked?" but "what exact certified grounded evidence is still missing, and what should the next conservative live session accomplish?"

- it writes `next_live_plan.json` and `next_live_plan.md` under `lab\logs\eval\registry\`
- it reuses the certified registry state first, then reuses `registry_summary.json`, `profile_recommendation.json`, and `responsive_trial_gate.json` when those artifacts already exist
- it is advisory and read-only. Basic scoring, registration, and responsive-gate evaluation still work if the planner is never run.
- it computes the evidence gap from certified grounded evidence only
- rehearsal, synthetic, workflow-validation-only, no-human, weak-signal, insufficient-data, and other non-certified live sessions stay visible in the explanation, but they do not shrink the real promotion gap
- it formalizes the missing-count fields that matter for promotion, including grounded conservative sessions, grounded conservative too-quiet sessions, distinct grounded too-quiet pair IDs, strong-signal keep-conservative thresholds, and responsive too-reactive blockers
- it emits a concrete next-session objective such as `collect-first-grounded-conservative-session`, `collect-more-grounded-conservative-sessions`, `collect-grounded-conservative-too-quiet-evidence`, `responsive-trial-ready`, `responsive-blocked-by-overreaction-history`, or `manual-review-before-next-session`
- it also emits a session target block with the next session profile, unchanged no-AI control lane, map, bot count, bot skill, minimum human-presence target, minimum patch-while-human-present target, minimum post-patch observation window, whether the next session can reduce the gap, whether it could open responsive if successful, and whether another conservative session would still be required afterward

Run it directly:

```powershell
powershell -NoProfile -File .\scripts\plan_next_live_session.ps1
```

Or use the thin wrapper:

```bat
scripts\plan_next_live_session.bat
```

Read the planner outputs like this:

- certification answers whether one pair counts toward promotion
- scorecard answers how one pair behaved
- registry summary answers the accumulated cross-session recommendation
- responsive gate answers whether the first live responsive trial is currently allowed
- next-live planner answers what evidence gap still remains and what the next real conservative session should try to prove

In the planner, "evidence gap" means the configured promotion thresholds minus the currently certified grounded evidence counts. If the next plan still says responsive is blocked, use `next_live_plan.md` before scheduling the next conservative session so the operator knows whether the goal is first grounded certification, another grounded conservative run, repeated grounded too-quiet evidence, or manual review.

## Responsive Trial Gate

Use `scripts\evaluate_responsive_trial_gate.ps1` when you need a disciplined operator-facing answer to "is the first real live responsive trial justified yet?"

- it writes `responsive_trial_gate.json`, `responsive_trial_gate.md`, `responsive_trial_plan.json`, and `responsive_trial_plan.md` under `lab\logs\eval\registry\`
- it reads the registry first and reuses `registry_summary.json` / `profile_recommendation.json` when they already exist
- thresholds live in `ai_director/testdata/responsive_trial_gate.json` and are intentionally strict
- it uses certified grounded evidence only. Registered sessions that fail certification still appear in the explanation, but they do not count toward promotion thresholds.
- rehearsal, synthetic, no-human, plumbing-valid-only, comparison-insufficient-data, insufficient-data, weak-signal, and validation-only sessions must not unlock the live responsive trial
- repeated certified grounded conservative-too-quiet sessions across distinct pair runs may open the gate
- grounded responsive-too-reactive evidence closes the gate and recommends reverting to `conservative`
- ambiguous grounded evidence stays `manual-review-needed`

Run it directly after summarizing the registry:

```powershell
powershell -NoProfile -File .\scripts\evaluate_responsive_trial_gate.ps1
```

Read the next live action like this:

- `responsive-trial-not-allowed`: the gate is still blocked because the real evidence is still insufficient, weak, or synthetic-only
- `collect-more-conservative-evidence`: some real grounded conservative evidence exists, but not enough repeated too-quiet evidence exists yet
- `keep-conservative`: real grounded conservative evidence already looks acceptable, so responsive should stay blocked
- `responsive-trial-allowed`: exactly one bounded live responsive trial is justified, and the generated plan becomes the operator runbook
- `responsive-revert-recommended`: grounded responsive evidence already shows overreaction, so the live default should move back to conservative
- `manual-review-needed`: the grounded evidence conflicts or still carries risk that needs an operator read

If the gate is blocked, `responsive_trial_plan.md` is a "not yet" explanation, not a ready launch plan. If the gate opens, the plan file carries the exact lane settings, success criteria, rollback rule, and post-run workflow.

## Synthetic Fixture Validation

The repository also carries deterministic synthetic pair packs under `ai_director/testdata/pair_sessions/`. They exist to validate the post-run decision stack before another real human-rich session is spent on the wrong branch.

- the fixtures are clearly marked synthetic and should never be treated as real live evidence
- each fixture reuses the same pair-pack shape as the live workflow: `pair_summary.json`, `comparison.json`, nested lane summaries/session packs, and replayable telemetry history
- the fixture families cover plumbing-only insufficient-data, sparse-human weak-signal, usable conservative keep/repeat cases, conservative-too-quiet responsive-candidate cases, responsive-too-reactive revert cases, and an ambiguous manual-review case
- the fixtures help prove that insufficient-data does not justify responsive, that one noisy run does not auto-promote responsive, and that too-quiet / too-reactive branches stay grounded and honest
- by default the responsive-trial gate excludes synthetic-only evidence from live promotion; the validation-only synthetic override exists only to exercise gate branches in tests

Regenerate the synthetic pair packs if the deterministic fixture source changes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\common.ps1; `$pythonExe = Get-PythonPath -PreferredPath ''; & `$pythonExe .\scripts\generate_pair_session_fixtures.py"
```

Run the dedicated fixture-backed decision tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\common.ps1; `$pythonExe = Get-PythonPath -PreferredPath ''; & `$pythonExe -m unittest ai_director.tests.test_pair_session_fixtures"
```

Run the compact end-to-end demo against the full fixture suite:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_fixture_decision_demo.ps1
```

That demo copies the synthetic pair packs into a temporary evaluation root, runs shadow review, scores every pair, registers them into a synthetic registry, and emits a compact summary. The demo is for workflow validation only. It does not replace real human evidence when choosing the next live profile.

Use the guided sufficiency rehearsal when you specifically need to validate the missing auto-stop success branch before the next real session:

```powershell
powershell -NoProfile -File .\scripts\run_guided_live_pair_session.ps1 -RehearsalMode -RehearsalFixtureId strong_signal_keep_conservative -RehearsalStepSeconds 2 -AutoStartMonitor -AutoStopWhenSufficient -MonitorPollSeconds 1 -RunPostPipeline
```

Read that rehearsal output conservatively:

- `guided_session\monitor_verdict_history.ndjson` should show the staged progression from `waiting-for-control-human-signal` through `sufficient-for-tuning-usable-review`
- `guided_session\final_session_docket.json` and `.md` should say the evidence origin is `rehearsal`
- `guided_session\registry\pair_sessions.ndjson` is isolated from the real registry on purpose
- `grounded_evidence_certificate.json` and `.md` in the rehearsal pair root should say the session is excluded from promotion and counts only as workflow validation
- `guided_session\registry\responsive_trial_gate.json` must stay closed when the registry contains only rehearsal evidence

Summarize one lane or compare control vs treatment with:

```powershell
powershell -NoProfile -File .\scripts\summarize_balance_eval.ps1 `
  -LaneRoot .\lab\logs\eval\<control-lane> `
  -CompareLaneRoot .\lab\logs\eval\<treatment-lane> `
  -OutputJson .\lab\logs\eval\comparison.json `
  -OutputMarkdown .\lab\logs\eval\comparison.md
```

## Replay-Driven Tuning Profiles

A tuning profile is a named bundle of bounded offline rule parameters used by the AI sidecar and the replay evaluator. The current catalog is stored in `ai_director/testdata/tuning_profiles.json` and exposes three starting points:

- `conservative`: higher human-signal thresholds, slower cooldown, and more caution near the decision boundary.
- `default`: current bounded baseline behavior and the safest reference point for regression checks.
- `responsive`: lower decision thresholds and a shorter cooldown to react earlier to sustained imbalance.

Run the replay/profile sweep before spending live mixed-session time:

```powershell
powershell -NoProfile -File .\scripts\run_balance_parameter_sweep.ps1
powershell -NoProfile -File .\scripts\run_balance_parameter_sweep.ps1 -Profiles conservative default responsive
```

The sweep writes `summary.json`, `summary.md`, `comparison.json`, and `comparison.md` under `lab\logs\eval\replay_sweeps\<timestamp>\`. Those artifacts answer:

- which profile is safest
- which profile is most conservative
- which profile is most responsive
- which profile best avoids oscillation
- which profile best avoids underreaction
- which profile is the best next candidate for a live mixed-session run

Use the sweep results to pick the next live treatment profile, then pass the same name back into `scripts\run_balance_eval.ps1`, `scripts\run_mixed_balance_eval.ps1`, or `scripts\run_control_treatment_pair.ps1` with `-TuningProfile <name>`. Start live pair work with `conservative`. Only move to `responsive` after the responsive-trial gate opens on repeated real grounded conservative-too-quiet evidence.

## Replay Scenarios

Run the deterministic replay and summary tests without a live server:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\common.ps1; `$pythonExe = Get-PythonPath -PreferredPath ''; & `$pythonExe -m unittest ai_director.tests.test_decision ai_director.tests.test_replay_scenarios ai_director.tests.test_tuning_profiles"
```

The replay fixture set now covers more realistic mixed-session patterns:

- one human steadily outperforming bots
- one human repeatedly getting stomped by bots
- human joins late after the lane already started
- human joins after an AI waiting patch was already emitted
- alternating advantage that can become oscillatory
- humans absent after an initial join
- brief human joins that should stay insufficient-data
- strong frag-gap spikes followed by stabilization
- close games with only mild imbalance where AI should remain conservative
- near-threshold lanes where conservative should hold and responsive profiles may react
- sustained moderate imbalance where a quicker profile should respond sooner
- noisy threshold alternation where aggressive profiles risk oscillation
- overcorrection-risk sequences where hysteresis matters after the first patch
- patch activity that only happened before humans joined and therefore should not be treated as live evidence

## Evaluation Verdicts

- `stable`: bounded actions and limited reversals, with recent telemetry near equilibrium.
- `underactive`: strong momentum persists with too little corrective action.
- `oscillatory`: emitted or applied patches keep flipping between stronger and weaker settings.
- `insufficient-data`: the lane did not capture enough telemetry to judge behavior.

Lane quality is reported separately from the stability verdict:

- `ai-healthy-no-humans`: plumbing worked, but no human signal existed.
- `ai-healthy-human-sparse`: humans joined briefly, but not long enough to judge rebalancing.
- `ai-healthy-human-usable`: enough human presence existed to judge treatment behavior.
- `ai-healthy-human-rich`: enough human presence existed to treat the lane as a stronger mixed-session sample.

The no-AI control lane uses the same human-signal buckets with a `control-baseline-...` prefix so control-vs-treatment comparisons can reject weak samples cleanly.

Treatment-response evidence quality is reported separately so a lane can be plumbing-healthy and tuning-usable while still being weak for tuning decisions:

- `insufficient-data`: not enough human signal existed to judge treatment behavior
- `weak-signal`: humans were present, but there was little or no grounded post-patch evidence
- `usable-signal`: humans were present long enough to observe at least one grounded post-patch window
- `strong-signal`: a richer session captured multiple grounded post-patch windows

Pair-level comparison verdicts are reported separately:

- `comparison-insufficient-data`: the pair never captured enough human signal to support a fair comparison
- `comparison-weak-signal`: one lane was usable or treatment hinted at something, but the pair still lacks grounded live comparison evidence
- `comparison-usable`: both lanes were human-usable and treatment produced at least one grounded post-patch observation window
- `comparison-strong-signal`: both lanes were human-usable and treatment produced multiple grounded post-patch windows

## Visual Studio 2022 Build

- Solution: `hl-bots-ai.sln`
- Project: `jk_botti_mm.vcxproj`
- Configurations: `Debug|Win32`, `Release|Win32`
- Platform toolset: `v143`
- Staged output: `build/bin/<Configuration>/Win32/addons/jk_botti/dlls/jk_botti_mm.dll`

The Windows project preserves the upstream source layout instead of moving source files into a separate tree. The upstream `Makefile` remains in place for non-Windows builds.

## AI Balance Loop

Telemetry is emitted on a slow cadence controlled by `jk_ai_balance_interval` and includes:

- timestamp and match identifier,
- map name,
- human and bot counts,
- top human and top bot frags/deaths,
- rolling recent human and bot kills per minute,
- frag gap between the best human and best bot,
- current default bot skill and active balance settings.

The default fallback rules use only public match signals and adjust cautiously:

- if humans are pulling ahead, make bots slightly stronger and optionally add one bot,
- if bots are pulling ahead, make bots slightly weaker and optionally remove one bot,
- if the match looks close, keep settings stable.

The sidecar writes compact JSON patches atomically. The plugin ignores stale, partial, duplicate, or out-of-match patches.

## Offline Fallback Mode

Leave `OPENAI_API_KEY` unset and run:

```powershell
powershell -NoProfile -File .\scripts\run_ai_director.ps1
```

The sidecar will use the deterministic rules engine in `ai_director/decision.py`. This is the default lab mode, it is what `scripts\run_test_stand_with_bots.bat` uses when no API key is present, and it requires no internet access.

## OpenAI Mode

Copy `ai_director/.env.example` to `ai_director/.env` or create a repo-root `.env`, then set:

```dotenv
OPENAI_API_KEY=your-key-here
OPENAI_MODEL=gpt-4o-mini
AI_DIRECTOR_POLL_INTERVAL=5
AI_DIRECTOR_LOG_LEVEL=INFO
```

When a key is present, the sidecar calls the OpenAI Python SDK through the Responses API and requests strict JSON output. The response is validated and clamped before a patch file is written. If the API call or SDK path fails, the sidecar logs the error and falls back to deterministic rules.

After setting `OPENAI_API_KEY`, rerun `scripts\run_test_stand_with_bots.bat` or the underlying PowerShell launcher and the same test stand will switch from fallback mode to OpenAI-backed recommendations automatically.

## Logs And Runtime Files

- Telemetry bridge: `valve/addons/jk_botti/runtime/ai_balance/telemetry.json`
- Patch bridge: `valve/addons/jk_botti/runtime/ai_balance/patch.json`
- Telemetry history: `valve/addons/jk_botti/runtime/ai_balance/history/telemetry-<match_id>.ndjson`
- Patch recommendation history: `valve/addons/jk_botti/runtime/ai_balance/history/patch-<match_id>.ndjson`
- Patch apply history: `valve/addons/jk_botti/runtime/ai_balance/history/patch_apply-<match_id>.ndjson`
- Bot settings history: `valve/addons/jk_botti/runtime/ai_balance/history/bot_settings-<match_id>.ndjson`
- Bootstrap attach log: `valve/addons/jk_botti/runtime/bootstrap.log`
- Generated bot test config: `lab/hlds/valve/addons/jk_botti/jk_botti_<map>.cfg`
- Bot test config template: `addons/jk_botti/test_bots.cfg`
- Generated no-AI baseline config: `lab/hlds/valve/addons/jk_botti/jk_botti_<map>.cfg`
- AI director logs: `lab/logs/ai_director.stdout.log` and `lab/logs/ai_director.stderr.log`
- HLDS logs: `lab/logs/hlds.stdout.log` and `lab/logs/hlds.stderr.log`
- Evaluation lane artifacts: `lab/logs/eval/<timestamp>-<mode>-...`
- Mixed-session session packs: `lab/logs/eval/<timestamp>-<mode>-.../session_pack.json`
- Pair packs: `lab/logs/eval/pairs/<timestamp>-...`
- Pair-session registry artifacts: `lab/logs/eval/registry/<artifact>`
- Pair summaries: `lab/logs/eval/pairs/<timestamp>-.../pair_summary.json` and `pair_summary.md`
- Pair comparisons: `lab/logs/eval/pairs/<timestamp>-.../comparison.json` and `comparison.md`
- Pair-session registry ledger: `lab/logs/eval/registry/pair_sessions.ndjson`
- Pair-session registry summaries and planning artifacts: `lab/logs/eval/registry/registry_summary.json`, `registry_summary.md`, `profile_recommendation.json`, `profile_recommendation.md`, `responsive_trial_gate.json`, `responsive_trial_plan.json`, `next_live_plan.json`, and `next_live_plan.md`
- Server install root by default: `lab/hlds`

The generated map-specific config pins `botskill`, `min_bots`, `max_bots`, and a matching set of `addbot` lines so the requested bot pool comes up predictably and can be regenerated safely on each launcher run.

For evaluation runs, the plugin now preserves per-match append-only NDJSON history in the runtime `history` directory. The no-AI control lane still never polls or applies patches, but it does emit read-only telemetry snapshots so the control and treatment lanes can be compared without enabling balance changes in the baseline.

## Scripts

- `scripts/build_vs2022.ps1`: builds the VS2022 solution and verifies the staged DLL exists.
- `scripts/setup_test_stand.ps1`: installs or updates SteamCMD/HLDS, downloads Metamod-P, writes `plugins.ini`, patches `liblist.gam`, and copies jk_botti lab files.
- `scripts/run_ai_director.ps1`: runs the Python sidecar once or as a background process.
- `scripts/run_server.ps1`: launches HLDS for the `valve` mod on a local LAN-safe configuration.
- `scripts/run_lab.ps1`: convenience entry point that sets up the lab, launches the sidecar, and launches HLDS.
- `scripts/run_test_stand_with_bots.ps1`: one-command test launcher that builds, prepares the lab, generates the map-specific bot config, starts the sidecar, and starts HLDS.
- `scripts/run_test_stand_with_bots.bat`: `cmd.exe` wrapper for the one-command local bot test flow, with backward-compatible positional arguments and direct named-argument passthrough.
- `scripts/run_standard_bots_crossfire.ps1`: baseline launcher that builds, prepares the lab, writes a deterministic no-AI map config with `jk_ai_balance_enabled 0`, and starts HLDS without the Python sidecar.
- `scripts/run_standard_bots_crossfire.bat`: `cmd.exe` wrapper for the baseline no-AI crossfire flow, with backward-compatible positional arguments and direct named-argument passthrough.
- `scripts/run_balance_eval.ps1`: launches one control or treatment lane, waits for the requested duration, copies artifacts into a lane folder, and writes `summary.json` plus `summary.md`.
- `scripts/run_mixed_balance_eval.ps1`: thin helper for live mixed human-vs-bot treatment runs that prints join targets, defaults to the conservative next-live profile, and writes the same lane/session-pack artifacts.
- `scripts/run_mixed_balance_eval.bat`: `cmd.exe` wrapper for the mixed-session helper.
- `scripts/run_control_treatment_pair.ps1`: thin paired workflow helper that runs the control lane and treatment lane, preserves both session packs, and writes the combined pair summary/comparison pack.
- `scripts/run_control_treatment_pair.bat`: `cmd.exe` wrapper for the paired control-vs-treatment helper.
- `scripts/run_guided_live_pair_session.ps1`: guided conservative-first operator workflow that runs preflight, the paired capture, optional auto-start monitoring with sufficient-only auto-stop, the full post-session evidence pipeline, and the final session docket.
- `scripts/run_guided_live_pair_session.bat`: `cmd.exe` wrapper for the guided live pair-session workflow.
- `scripts/plan_next_live_session.ps1`: computes the certified-grounded promotion gap, emits `next_live_plan.json` plus `next_live_plan.md`, and recommends the next live profile and session objective.
- `scripts/plan_next_live_session.bat`: `cmd.exe` wrapper for the next-live session planner.
- `scripts/run_guided_pair_rehearsal.ps1`: deterministic synthetic pair runner used only by guided rehearsal mode so the sufficiency and auto-stop success branch can be validated without a real human-rich session.
- `scripts/preflight_real_pair_session.ps1`: operator-facing preflight that verifies build output, required scripts, known paths, control/treatment ports, the conservative treatment profile, and optional local client-helper readiness before a real human pair session.
- `scripts/preflight_real_pair_session.bat`: `cmd.exe` wrapper for the real pair-session preflight helper.
- `scripts/review_latest_pair_run.ps1`: finds the newest pair pack, prints the key artifact paths, summarizes the control/treatment verdicts, and points to the next artifact worth reading.
- `scripts/score_latest_pair_session.ps1`: writes `scorecard.json` and `scorecard.md` into a pair pack, classifies the treatment lane as too quiet / appropriately conservative / inconclusive / too reactive, and emits an explicit next-action recommendation.
- `scripts/score_latest_pair_session.bat`: `cmd.exe` wrapper for the scorecard helper.
- `scripts/register_pair_session_result.ps1`: appends one normalized pair-session result into the persistent registry ledger and skips duplicate pair packs by default.
- `scripts/register_pair_session_result.bat`: `cmd.exe` wrapper for the pair-session registry helper.
- `scripts/summarize_pair_session_registry.ps1`: summarizes accumulated pair-session evidence, emits a conservative profile recommendation for the next live action, and can optionally refresh the responsive gate or next-live planner artifacts.
- `scripts/launch_local_hldm_client.ps1`: optional helper that resolves a local Half-Life client and launches or dry-runs a local join command.
- `scripts/launch_local_hldm_client.bat`: `cmd.exe` wrapper for the local client helper.
- `scripts/summarize_balance_eval.ps1`: Windows wrapper around the Python evaluator for one lane or a control-vs-treatment pair.
- `scripts/smoke_test.ps1`: classifies attach/load state for AI and no-AI runs, distinguishes healthy no-AI and healthy AI outcomes, and fails early on avoidable config warnings.
- `ai_director/tools/summarize_eval.py`: machine-readable and human-readable summary generator used by the PowerShell wrapper.
- `scripts/inspect_plugin_exports.ps1`: checks the Win32 DLL architecture and the required HL/Metamod exports with `dumpbin`.
- `scripts/inspect_plugin_dependencies.ps1`: reports the configured MSVC runtime mode and binary DLL dependents.
- `scripts/inspect_plugin_path.ps1`: verifies `plugins.ini`, the deployed DLL path, and the bootstrap log location inside the lab.
- `scripts/collect_attach_diagnostics.ps1`: gathers the current export, dependency, path, bootstrap, and HLDS log evidence in one report.

All scripts accept overridable lab paths, and the setup script supports custom SteamCMD and Metamod download sources.

## Troubleshooting Attach

- Check `lab\hlds\valve\addons\metamod\plugins.ini`. It should contain `win32 addons/jk_botti/dlls/jk_botti_mm.dll`. `scripts\inspect_plugin_path.ps1` verifies the configured path and the copied DLL under `lab\hlds\valve\addons\jk_botti\dlls\jk_botti_mm.dll`.
- Check architecture and exports with `scripts\inspect_plugin_exports.ps1`. The Release lab DLL should report `14C machine (x86)` / `PE32`, and the export table should include `GiveFnptrsToDll`, `Meta_Query`, `Meta_Attach`, and `Meta_Detach`.
- Check runtime dependencies with `scripts\inspect_plugin_dependencies.ps1`. `Release|Win32` is configured for `MultiThreaded` (`/MT`), and the live lab DLL should depend only on `KERNEL32.dll`, `WSOCK32.dll`, and `WS2_32.dll`.
- Check the earliest bootstrap log at `lab\hlds\valve\addons\jk_botti\runtime\bootstrap.log`. It records `DllMain`, `GiveFnptrsToDll`, `Meta_Query`, `Meta_Attach`, and `Meta_Detach` entry/result lines.
- Use `scripts\run_standard_bots_crossfire.bat` first when attach is in doubt. It removes the Python sidecar from the startup path and keeps the debug surface limited to `HLDS -> Metamod -> jk_botti_mm.dll`.
- Interpret `scripts\smoke_test.ps1` by mode. `-Mode NoAI` should return `no-ai-healthy`; `-Mode AI` should return `ai-healthy`. Other statuses distinguish `hlds-did-not-start`, `metamod-did-not-load`, `plugin-dll-file-missing`, `plugin-dll-load-failed`, `plugin-dll-loaded-but-meta-query-not-reached`, `plugin-loaded-but-meta-query-failed`, `plugin-passed-meta-query-but-did-not-attach`, `plugin-attached-but-bootstrap-log-missing`, `plugin-attached-but-config-warning-present`, `plugin-attached-but-no-telemetry`, `telemetry-emitted-but-no-patch-path-yet`, `telemetry-and-patch-emitted-but-no-apply-log-yet`, `ai-sidecar-not-yet-running`, `no-ai-path-active-but-sidecar-running`, and `no-ai-path-active-but-unexpected-patch-output`.
- The earlier no-AI `unknown command: 'jk_ai_balance_enabled 0'` line was a JK Botti parser classification issue, not an engine failure. The parser now detects registered cvars and forwards them as server commands without printing that avoidable warning.

## Known Limitations

- Full end-to-end smoke coverage still depends on external HLDS and Metamod downloads.
- The OpenAI path is optional and deliberately not used from per-frame bot code.
- The AI layer only adjusts coarse balance knobs. It does not rewrite waypointing, aim code, or hidden-information access.
- The current telemetry model is tuned for HLDM free-for-all, not team objective mods.
- Live AI lanes without human players mostly validate idle and bounded behavior. Deeper balance tuning still benefits from replay scenarios or mixed human-vs-bot sessions.
- Runtime paths assume the standard `valve` HLDM layout for the Windows lab scripts.

## Upstream Attribution

This repository incorporates the upstream jk_botti project from [Bots-United/jk_botti](https://github.com/Bots-United/jk_botti). Original source files, licenses, and addon content were preserved and extended rather than relicensed or rewritten wholesale.
