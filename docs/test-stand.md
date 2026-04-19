# HLDM Test Stand

PROMPT_ID_BEGIN
HLDM-JKBOTTI-AI-STAND-20260415-34
PROMPT_ID_END

This document describes the Windows-first local HLDM lab added on top of jk_botti.

## One-Command Test Launch

The current AI launcher remains the normal sidecar-backed test path:

```bat
scripts\run_test_stand_with_bots.bat
```

The new no-AI baseline launcher is for standard jk_botti testing on `crossfire` without the Python sidecar:

```bat
scripts\run_standard_bots_crossfire.bat
```

Legacy positional arguments for `scripts\run_test_stand_with_bots.bat`:

- `%1`: map name, default `stalkyard`
- `%2`: bot count, default `4`
- `%3`: bot skill, default `3`
- `%4`: lab root, default `.\lab`

Examples:

```bat
scripts\run_test_stand_with_bots.bat
scripts\run_test_stand_with_bots.bat crossfire
scripts\run_test_stand_with_bots.bat stalkyard 6
scripts\run_test_stand_with_bots.bat stalkyard 6 2
```

Legacy positional arguments for `scripts\run_standard_bots_crossfire.bat`:

- `%1`: map name, default `crossfire`
- `%2`: bot count, default `4`
- `%3`: bot skill, default `3`
- `%4`: lab root, default `.\lab`

Examples:

```bat
scripts\run_standard_bots_crossfire.bat
scripts\run_standard_bots_crossfire.bat crossfire
scripts\run_standard_bots_crossfire.bat crossfire 6
scripts\run_standard_bots_crossfire.bat crossfire 6 2
```

If the first batch argument starts with `-`, both wrappers pass the full argument list straight through to the PowerShell implementation. This is the preferred repeat-test form because it exposes the useful knobs without duplicating logic in `cmd.exe`.

Named passthrough examples:

```bat
scripts\run_standard_bots_crossfire.bat -Map crossfire -BotCount 4 -BotSkill 3 -Port 27016 -SkipSteamCmdUpdate -SkipMetamodDownload
scripts\run_standard_bots_crossfire.bat -Map crossfire -BotCount 6 -BotSkill 2 -LabRoot D:\Labs\hl-bots-ai -Port 27018 -SkipSteamCmdUpdate -SkipMetamodDownload
scripts\run_test_stand_with_bots.bat -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -SkipSteamCmdUpdate -SkipMetamodDownload
scripts\run_test_stand_with_bots.bat -Map stalkyard -BotCount 6 -BotSkill 2 -LabRoot D:\Labs\hl-bots-ai -Port 27019 -SkipSteamCmdUpdate -SkipMetamodDownload
scripts\run_control_treatment_pair.bat -Map crossfire -BotCount 4 -BotSkill 3 -ControlPort 27016 -TreatmentPort 27017 -SkipSteamCmdUpdate -SkipMetamodDownload
```

The batch file wraps `scripts\run_test_stand_with_bots.ps1`, which runs these steps in order:

1. `scripts\build_vs2022.ps1`
2. `scripts\setup_test_stand.ps1`
3. `scripts\run_ai_director.ps1`
4. `scripts\run_server.ps1`

The launcher prints the resolved settings before launch, regenerates the map-specific bot test config safely on each run, writes process output under `lab\logs`, and returns a nonzero exit code if the AI director or HLDS dies immediately during startup.

The no-AI batch file wraps `scripts\run_standard_bots_crossfire.ps1`, which runs these steps in order:

1. `scripts\build_vs2022.ps1`
2. `scripts\setup_test_stand.ps1`
3. writes `lab\hlds\valve\addons\jk_botti\jk_botti_<map>.cfg` with the deterministic standard jk_botti baseline
4. `scripts\run_server.ps1`

This baseline launcher automates the existing manual crossfire flow, uses `.\lab` by default, writes logs under `lab\logs`, sets `jk_ai_balance_enabled 0`, and does not start `scripts\run_ai_director.ps1`.

## Fast Local Iteration

Use the no-AI baseline as the primary quick loop when you only need HLDS, Metamod, and `jk_botti_mm.dll`:

```bat
scripts\run_standard_bots_crossfire.bat -Map crossfire -BotCount 4 -BotSkill 3 -Port 27016 -SkipSteamCmdUpdate -SkipMetamodDownload
```

This keeps `crossfire` as the default baseline map, preserves `jk_ai_balance_enabled 0` in the generated config, leaves the Python sidecar off by design, and still writes all launcher output under `lab\logs`.

Use the AI launcher when you need sidecar, telemetry, and patch-path verification:

```bat
scripts\run_test_stand_with_bots.bat -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -SkipSteamCmdUpdate -SkipMetamodDownload
```

The skip flags are intended for repeated local runs after SteamCMD/HLDS and Metamod are already present. `-Port` is safe to vary between sessions for side-by-side manual checks.

## Default Lab Layout

By default the scripts use `.\lab` under the repository root:

- `lab\tools\steamcmd\`: SteamCMD install if one is not already provided.
- `lab\hlds\`: HLDS dedicated server root installed through SteamCMD app `90` with `mod valve`.
- `lab\logs\`: HLDS stdout/stderr capture for the no-AI launcher and HLDS plus sidecar logs for the AI launcher.
- `lab\logs\eval\`: timestamped control/treatment lane folders with copied artifacts and summaries.
- `lab\logs\eval\pairs\`: bounded pair packs containing nested control/treatment lane folders plus combined comparison artifacts.
- `lab\logs\eval\registry\`: append-only pair-session ledger plus cross-session summary and profile-recommendation artifacts.
- `lab\hlds\valve\addons\jk_botti\runtime\ai_balance\`: telemetry and patch bridge folder used by the plugin and sidecar.
- `lab\hlds\valve\addons\jk_botti\runtime\ai_balance\history\`: per-match append-only NDJSON history.
- `lab\hlds\valve\addons\jk_botti\jk_botti_<map>.cfg`: generated map-specific bot test config used by the launcher.

## Setup Flow

`scripts/setup_test_stand.ps1` performs these steps:

1. Builds `hl-bots-ai.sln` for `Release|Win32` unless `-SkipBuild` is passed.
2. Locates SteamCMD or downloads it into the lab tools directory.
3. Installs or updates HLDS for `valve` with Steam app `90`.
4. Downloads Metamod-P for Windows unless `-SkipMetamodDownload` is passed.
5. Copies `addons/metamod` files into the HLDS mod tree.
6. Rewrites `valve/liblist.gam` to load Metamod.
7. Writes `valve/addons/metamod/plugins.ini` to load `addons/jk_botti/dlls/jk_botti_mm.dll`.
8. Copies repo `addons/jk_botti` content and the staged DLL into the server install.

`scripts\run_test_stand_with_bots.ps1` then writes `jk_botti_<map>.cfg` from the checked-in `addons\jk_botti\test_bots.cfg` template so the requested bot count and skill are explicit for that launch.

`scripts\run_standard_bots_crossfire.ps1` writes the same map-specific filename but uses the standard no-AI baseline values for jk_botti, changing only `botskill`, `min_bots`, `max_bots`, and the matching `addbot` lines when different arguments are requested.

## Common Commands

Build only:

```powershell
powershell -NoProfile -File .\scripts\build_vs2022.ps1 -Configuration Release -Platform Win32
```

Prepare the lab with explicit paths:

```powershell
powershell -NoProfile -File .\scripts\setup_test_stand.ps1 `
  -LabRoot D:\Labs\hl-bots-ai `
  -HldsRoot D:\Labs\hl-bots-ai\hlds `
  -ToolsRoot D:\Labs\hl-bots-ai\tools
```

Run only the AI sidecar:

```powershell
powershell -NoProfile -File .\scripts\run_ai_director.ps1 `
  -LabRoot .\lab `
  -TuningProfile default `
  -PollInterval 5
```

Run only the server:

```powershell
powershell -NoProfile -File .\scripts\run_server.ps1 `
  -LabRoot .\lab `
  -Map stalkyard `
  -MaxPlayers 8 `
  -Port 27015
```

Run the whole lab:

```powershell
powershell -NoProfile -File .\scripts\run_lab.ps1 -Map stalkyard
```

Run the one-command no-AI baseline launcher from `cmd.exe`:

```bat
scripts\run_standard_bots_crossfire.bat
scripts\run_standard_bots_crossfire.bat crossfire
scripts\run_standard_bots_crossfire.bat crossfire 6
scripts\run_standard_bots_crossfire.bat crossfire 6 2
```

Run the one-command no-AI baseline launcher from `cmd.exe` with named passthrough arguments:

```bat
scripts\run_standard_bots_crossfire.bat -Map crossfire -BotCount 4 -BotSkill 3 -Port 27016 -SkipSteamCmdUpdate -SkipMetamodDownload
```

Run the one-command no-AI baseline launcher from PowerShell:

```powershell
powershell -NoProfile -File .\scripts\run_standard_bots_crossfire.ps1 -Map crossfire -BotCount 4 -BotSkill 3
```

Run the one-command bot launcher from PowerShell:

```powershell
powershell -NoProfile -File .\scripts\run_test_stand_with_bots.ps1 -Map stalkyard -BotCount 4 -BotSkill 3
```

Run the one-command AI launcher from `cmd.exe` with named passthrough arguments:

```bat
scripts\run_test_stand_with_bots.bat -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -SkipSteamCmdUpdate -SkipMetamodDownload
```

Smoke test the running lab:

```powershell
powershell -NoProfile -File .\scripts\smoke_test.ps1 -Map stalkyard -BotCount 4 -BotSkill 3 -TimeoutSeconds 120
```

Smoke test the no-AI crossfire baseline:

```powershell
powershell -NoProfile -File .\scripts\smoke_test.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -Mode NoAI -TimeoutSeconds 60
```

Run a control-lane balance capture:

```powershell
powershell -NoProfile -File .\scripts\run_balance_eval.ps1 -Mode NoAI -Map crossfire -BotCount 4 -BotSkill 3 -Port 27016 -DurationSeconds 50 -SkipSteamCmdUpdate -SkipMetamodDownload
```

Run an AI treatment-lane balance capture:

```powershell
powershell -NoProfile -File .\scripts\run_balance_eval.ps1 -Mode AI -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -DurationSeconds 80 -TuningProfile default -SkipSteamCmdUpdate -SkipMetamodDownload
```

Run an AI treatment lane intended for human participation:

```powershell
powershell -NoProfile -File .\scripts\run_balance_eval.ps1 -Mode AI -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -DurationSeconds 80 -TuningProfile conservative -WaitForHumanJoin -HumanJoinGraceSeconds 120 -LaneLabel mixed-session-treatment -SkipSteamCmdUpdate -SkipMetamodDownload
```

Use the dedicated mixed-session helper when the goal is to bring a human into the lane quickly:

```powershell
powershell -NoProfile -File .\scripts\run_mixed_balance_eval.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -DurationSeconds 80 -TuningProfile conservative -WaitForHumanJoin -HumanJoinGraceSeconds 120 -LaneLabel mixed-session-treatment -SkipSteamCmdUpdate -SkipMetamodDownload
```

The mixed-session helper prints the join target before launch and saves the same join instructions into the lane folder as `join_instructions.txt`.

Run the dedicated paired control+treatment workflow when the goal is a real human comparison pack:

```powershell
powershell -NoProfile -File .\scripts\run_control_treatment_pair.ps1 `
  -Map crossfire `
  -BotCount 4 `
  -BotSkill 3 `
  -ControlPort 27016 `
  -TreatmentPort 27017 `
  -DurationSeconds 80 `
  -WaitForHumanJoin `
  -HumanJoinGraceSeconds 120 `
  -TreatmentProfile conservative `
  -SkipSteamCmdUpdate `
  -SkipMetamodDownload
```

This pair runner is thin on purpose:

- it reuses `scripts\run_balance_eval.ps1` for both lanes instead of duplicating launch logic
- it runs the no-AI control lane first and the AI treatment lane second
- it preserves both lane session packs inside one pair root under `lab\logs\eval\pairs\`
- it prints and saves control and treatment join targets up front
- it prints an exact threshold-aware `scripts\monitor_live_pair_session.ps1` command so the operator can watch live evidence sufficiency in a second terminal
- it keeps the control lane sidecar-free while still honoring human-join-aware wait thresholds

Run the mission-driven conservative-first workflow when the goal is to execute the whole next live pair correctly with the least operator error:

```powershell
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1
```

Inspect the current mission-derived launch without starting it like this:

```powershell
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1 -DryRun
```

Run the same mission-driven workflow in deterministic rehearsal mode when you need to validate the sufficient auto-stop branch without a real human-rich session:

```powershell
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1 `
  -RehearsalMode `
  -RehearsalFixtureId strong_signal_keep_conservative `
  -RehearsalStepSeconds 2 `
  -AutoStopWhenSufficient `
  -MonitorPollSeconds 1
```

The guided runner remains a thin orchestrator over the existing helpers:

- it still runs `scripts\preflight_real_pair_session.ps1` first
- it now runs `scripts\prepare_next_live_session_mission.ps1` before launch so the operator sees the current mission brief path, recommended profile, and current next objective up front
- it still uses `scripts\run_control_treatment_pair.ps1` for the actual control and treatment capture
- in rehearsal mode it swaps only the pair runner for `scripts\run_guided_pair_rehearsal.ps1`, which stages monitor-compatible pair artifacts and then hands the finalized pair pack back to the same post-run helpers
- it can auto-start `scripts\monitor_live_pair_session.ps1` against the active pair root
- it can request an early stop only after the live monitor reaches a sufficient verdict, never on the `waiting-*` or insufficient-data states
- it still runs `scripts\review_latest_pair_run.ps1`, `scripts\run_shadow_profile_review.ps1`, `scripts\score_latest_pair_session.ps1`, `scripts\register_pair_session_result.ps1`, `scripts\summarize_pair_session_registry.ps1`, and `scripts\evaluate_responsive_trial_gate.ps1`
- it also runs `scripts\plan_next_live_session.ps1` in the normal post-run pipeline so the final docket can carry the current next-live objective and recommended profile
- it also runs `scripts\build_latest_session_outcome_dossier.ps1` so the pair root gets `session_outcome_dossier.json` and `session_outcome_dossier.md`
- it also runs `scripts\evaluate_latest_session_mission.ps1` after the dossier step so the pair root gets `mission_attainment.json` and `mission_attainment.md`
- it snapshots the mission brief under `guided_session\mission\` once the pair root exists
- the mission-driven wrapper writes `guided_session\mission_execution.json` and `guided_session\mission_execution.md` so later closeout can compare the mission against the actual launch
- it writes `guided_session\final_session_docket.json` and `guided_session\final_session_docket.md` under the pair root after the run, and that docket points to the pre-run mission brief, the mission execution record, the post-run outcome dossier, and the mission-attainment closeout
- in rehearsal mode it writes an isolated validation-only registry under `guided_session\registry\` so real live ledgers stay untouched

Start the live monitor like this while the pair is running:

```powershell
powershell -NoProfile -File .\scripts\monitor_live_pair_session.ps1 -UseLatest -PollSeconds 5 -StopWhenSufficient
```

Or use the exact `-PairRoot` command printed by `scripts\run_control_treatment_pair.ps1` when you want the thresholds pinned to that pair pack explicitly.

Before a real human pair session, run the dedicated preflight:

```powershell
powershell -NoProfile -File .\scripts\preflight_real_pair_session.ps1
```

After a pair completes, review the latest pair pack with:

```powershell
powershell -NoProfile -File .\scripts\review_latest_pair_run.ps1
```

Then score the latest pair pack with:

```powershell
powershell -NoProfile -File .\scripts\score_latest_pair_session.ps1
```

Then certify whether that pair pack counts as real grounded promotion evidence:

```powershell
powershell -NoProfile -File .\scripts\certify_latest_pair_session.ps1
powershell -NoProfile -File .\scripts\certify_latest_pair_session.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
```

Register the latest scored pair pack into the append-only ledger:

```powershell
powershell -NoProfile -File .\scripts\register_pair_session_result.ps1
powershell -NoProfile -File .\scripts\register_pair_session_result.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
powershell -NoProfile -File .\scripts\register_pair_session_result.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack> -NotesPath .\lab\logs\eval\pairs\<pair-pack>\session_notes.md
```

Summarize the accumulated pair-session ledger after registration:

```powershell
powershell -NoProfile -File .\scripts\summarize_pair_session_registry.ps1
```

Emit the current next-live promotion-gap plan:

```powershell
powershell -NoProfile -File .\scripts\plan_next_live_session.ps1
powershell -NoProfile -File .\scripts\summarize_pair_session_registry.ps1 -EvaluateNextLiveSessionPlan
```

Emit the exact pre-run mission brief for the next live session:

```powershell
powershell -NoProfile -File .\scripts\prepare_next_live_session_mission.ps1
```

Run the replay/profile sweep before scheduling a longer live mixed-session:

```powershell
powershell -NoProfile -File .\scripts\run_balance_parameter_sweep.ps1
```

The sweep compares the named `conservative`, `default`, and `responsive` profiles offline and writes `summary.json`, `summary.md`, `comparison.json`, and `comparison.md` under `lab\logs\eval\replay_sweeps\<timestamp>\`.

Run the shadow review helper after a captured pair when you want a counterfactual answer for the next live profile:

```powershell
powershell -NoProfile -File .\scripts\run_shadow_profile_review.ps1 -UseLatest -Profiles conservative default responsive
```

That helper replays the saved treatment lane through the selected profiles and writes `shadow_profiles.json`, `shadow_profiles.md`, `shadow_recommendation.json`, and `shadow_recommendation.md` under the pair pack's `shadow_review\` subfolder.

Summarize a control-vs-treatment pair:

```powershell
powershell -NoProfile -File .\scripts\summarize_balance_eval.ps1 `
  -LaneRoot .\lab\logs\eval\<control-lane> `
  -CompareLaneRoot .\lab\logs\eval\<treatment-lane> `
  -OutputJson .\lab\logs\eval\comparison.json `
  -OutputMarkdown .\lab\logs\eval\comparison.md
```

## Paired Live Procedure

For the next real human-vs-bot session, prefer this sequence:

1. Generate `next_live_session_mission.md` or let the guided runner generate it automatically at startup.
2. Start `scripts\run_guided_live_pair_session.ps1` with the default `conservative` treatment profile.
3. Read the printed mission brief path, control join target, treatment join target, monitor status or exact monitor command, pair output root, and final-docket target.
4. Confirm the mission still says the session is targeting certified grounded conservative evidence before spending the real run.
5. Join the control lane first and keep a human present long enough to clear the printed human-signal thresholds.
6. Let the paired workflow advance to treatment, then join the treatment lane second.
7. If the guided runner auto-started the monitor, leave it alone. If it did not, run the printed exact `scripts\monitor_live_pair_session.ps1 -PairRoot ...` command in a second terminal.
8. Use `-AutoStopWhenSufficient` only when you want the guided runner to request an early stop after the monitor reaches `sufficient-for-tuning-usable-review` or `sufficient-for-scorecard`.
9. Keep the session running when the monitor still says any `waiting-*` verdict, and never treat `insufficient-data-timeout` as tuning proof.
10. Use manual stop instead of auto-stop when you want extra observation time, when an operator wants direct control, or when validating the no-human path.
11. Read `session_outcome_dossier.md` first after the run. Use `guided_session\final_session_docket.md` as the quick pointer to it.

Use rehearsal mode for workflow validation only:

- it should progress through `waiting-for-control-human-signal`, `waiting-for-treatment-human-signal`, `waiting-for-treatment-patch-while-humans-present`, `waiting-for-post-patch-observation-window`, and `sufficient-for-tuning-usable-review`
- with `-AutoStopWhenSufficient`, the guided runner should request stop only after the sufficient verdict appears
- after the rehearsal pair finalizes, the last monitor verdict should become `sufficient-for-scorecard`
- the saved pair pack, scorecard, final docket, certificate, and rehearsal registry should all make the synthetic rehearsal labeling explicit
- `grounded_evidence_certificate.json` and `.md` should say the rehearsal pack is excluded from promotion and counts only as workflow validation
- rehearsal success proves the workflow branch works; it does not prove the live tuning is good

The guided runner still delegates the work to the individual helpers above. It does not replace them with a second scoring engine.

The saved join helpers make the roles explicit:

- `control_join_instructions.txt`: no-AI baseline, `jk_ai_balance_enabled 0`, no sidecar
- `treatment_join_instructions.txt`: AI treatment lane, chosen tuning profile, expected join target
- `pair_join_instructions.txt`: the whole paired sequence, useful-session expectations, and pair-pack root

Why `conservative` is the default next live treatment profile:

- it demands more human signal before claiming usefulness
- it reacts more slowly near the boundary, which reduces the chance of overreading one noisy session
- it is the safest way to learn whether live treatment is too quiet before escalating to `responsive`

Try `responsive` only after the responsive-trial gate opens on repeated real grounded conservative-too-quiet evidence. One noisy scorecard or synthetic fixture alone is not enough.

Read the final guided docket like this:

- `control lane verdict`, `treatment lane verdict`, and `pair classification` come from the saved pair pack, not from an extra guided-only evaluator
- `scorecard recommendation` comes from `scripts\score_latest_pair_session.ps1`
- `shadow recommendation` comes from `scripts\run_shadow_profile_review.ps1`
- `registry recommendation state` comes from `scripts\summarize_pair_session_registry.ps1`
- `responsive gate verdict` comes from `scripts\evaluate_responsive_trial_gate.ps1`
- `primary operator action` compresses those real artifacts into one conservative next-step summary

Read the live monitor verdicts like this:

- `waiting-for-control-human-signal`: the control lane still lacks enough grounded human presence to be a fair baseline.
- `waiting-for-treatment-human-signal`: the control lane cleared the gate, but treatment still has too little human presence.
- `waiting-for-treatment-patch-while-humans-present`: treatment humans are present, but the AI still has not emitted enough live human-present patch events.
- `waiting-for-post-patch-observation-window`: treatment has already patched live, but the post-patch observation time is still too short to stop honestly.
- `sufficient-for-tuning-usable-review`: the minimum honest stop bar is met. The operator can end the live pair and move to review.
- `sufficient-for-scorecard`: the pair pack is already finalized and the same grounded stop bar is satisfied, so the scorecard helper can run immediately.
- `insufficient-data-timeout`: the session ended before the grounded evidence gate cleared.
- `blocked-no-active-pair-run`: the monitor cannot find an active pair root to observe.

`sufficient-for-tuning-usable-review` means both lanes captured enough human presence, treatment patched while humans were present, and there is already a meaningful post-patch observation window. `sufficient-for-scorecard` means that same evidence gate is satisfied and the pair artifacts are already complete enough for `scripts\score_latest_pair_session.ps1`.

Shadow review is the intermediate check before doing that with a real human session. It answers what `default` and `responsive` would have done against the same captured treatment-lane history without pretending that offline replay is stronger than real human evidence.

Read the shadow recommendation like this:

- `keep-conservative`: the captured lane does not justify a live profile change yet.
- `conservative-and-default-similar`: shadow `default` stayed materially similar to the captured conservative lane.
- `insufficient-data-no-promotion`: the captured lane never cleared the human-signal gate strongly enough for promotion.
- `conservative-looks-too-quiet-responsive-candidate`: conservative looks too quiet and responsive would have added more grounded treatment activity without tripping the guardrails.
- `responsive-would-have-overreacted`: responsive looked too reactive in counterfactual replay, so conservative should stay live.

## Cross-Session Evidence Ledger

Use the registry helpers to move from single scorecards to accumulated live evidence.

- `scripts\register_pair_session_result.ps1` appends one normalized registry entry into `lab\logs\eval\registry\pair_sessions.ndjson`.
- registration defaults to the latest pair pack, but `-PairRoot` can target any existing pair pack.
- duplicate pair packs are skipped by default with a clear message instead of being re-registered silently.
- registration also writes `grounded_evidence_certificate.json` and `grounded_evidence_certificate.md` under the pair root so the certification result travels with the pair pack.
- registry entries record the pair ID/root, sortable run identity, map, bot count, bot skill, control/treatment lane labels, treatment profile, pair classification, lane verdicts, evidence quality, whether treatment patched while humans were present, whether a meaningful post-patch window existed, scorecard recommendation, treatment-behavior assessment, optional shadow-review decision fields when present, whether the session is tuning-usable, optional notes path, embedded prompt/commit metadata when available, and grounded-evidence certification fields.
- notes remain optional. Pass `-NotesPath` or drop a notes file into the pair root if an operator wants to keep lightweight context with the objective evidence.
- `scripts\summarize_pair_session_registry.ps1` writes `registry_summary.json`, `registry_summary.md`, `profile_recommendation.json`, and `profile_recommendation.md` under `lab\logs\eval\registry\`.
- `scripts\summarize_pair_session_registry.ps1 -EvaluateResponsiveTrialGate` can refresh the latest responsive-trial gate in the same pass.
- `scripts\summarize_pair_session_registry.ps1 -EvaluateNextLiveSessionPlan` can also refresh `next_live_plan.json` and `next_live_plan.md` in the same pass.
- `scripts\prepare_next_live_session_mission.ps1` writes `next_live_session_mission.json` and `next_live_session_mission.md` for the very next live run.
- `scripts\analyze_latest_grounded_session.ps1` writes `grounded_session_analysis.json`, `grounded_session_analysis.md`, `promotion_gap_delta.json`, and `promotion_gap_delta.md` for the latest pair or a specific `-PairRoot`.
- a pair counts toward promotion only when it is certified as grounded evidence: live origin, not rehearsal, not synthetic, minimum human-signal thresholds met, treatment patched while humans were present, a meaningful post-patch observation window exists, and the pair clears `tuning-usable` or stronger.
- rehearsal, synthetic, no-human, plumbing-valid-only, comparison-insufficient-data, insufficient-data, and weak-signal sessions stay in the ledger for auditability but are excluded from promotion counts by reason.
- the summary answers how many total registered sessions exist, how many are certified grounded sessions, how many were excluded, why they were excluded, how often treatment patched while humans were present, whether the certified dataset is still dominated by insufficient-data or weak-signal runs, how often shadow review suggested keep conservative, insufficient-data-no-promotion, responsive-candidate, or responsive-too-reactive, and whether responsive is justified or should be rejected or reverted.
- profile promotion stays intentionally conservative: non-certified sessions do not justify responsive, one noisy session does not justify a profile change, and conservative remains the default until repeated certified grounded evidence says otherwise.

Interpret the aggregate recommendation like this:

- `keep-conservative`: the current live default is still behaving safely.
- `collect-more-conservative-evidence`: there is some usable signal, but not enough repeated grounded evidence yet to promote or reject conservative.
- `conservative-validated-try-responsive`: only justified after repeated grounded conservative sessions show that conservative is consistently too quiet under real human presence.
- `responsive-too-reactive-revert-to-conservative`: grounded responsive evidence already shows overreaction and the next live profile should move back to conservative.
- `insufficient-data-repeat-session`: the registry is still dominated by plumbing-only or no-human evidence.
- `weak-signal-repeat-session`: humans joined, but the accumulated post-patch evidence is still too weak for a profile change.
- `manual-review-needed`: the ledger has conflicting grounded evidence or a guardrail concern that needs a manual read before the next live action.

## Latest-Session Delta Analysis

Use `scripts\analyze_latest_grounded_session.ps1` when you need the explicit post-session answer to "did the latest pair count, and exactly what changed because of it?"

- it writes `grounded_session_analysis.json`, `grounded_session_analysis.md`, `promotion_gap_delta.json`, and `promotion_gap_delta.md`
- it compares the registry stack with and without the latest pair counted, then reports which grounded deficits moved and which ones did not
- `counts_toward_promotion = false` means the latest pair remained visible but did not reduce the real responsive-promotion gap
- "the latest session changed something" means the helper shows a real delta in certified grounded evidence, next-step recommendation, or responsive blocker state
- no-human, rehearsal, synthetic, weak-signal, and otherwise excluded sessions may legitimately end as `no-impact-non-grounded-session`
- use `-PairRoot` when the newest saved pair pack is not the session you want to explain

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\analyze_latest_grounded_session.ps1
powershell -NoProfile -File .\scripts\analyze_latest_grounded_session.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
```

## Outcome Dossier

Use `scripts\build_latest_session_outcome_dossier.ps1` when the operator wants one post-session artifact instead of manually reading scorecard, certification, latest-session delta, responsive gate, and next-live planner outputs separately.

- it writes `session_outcome_dossier.json` and `session_outcome_dossier.md` into the pair root
- it reuses the existing scorecard, shadow review, certification, and latest-session delta helpers instead of inventing a second decision engine
- it includes the registry/gate/planner state before and after counting the latest session when that comparison is available
- it is broader than scorecard alone: scorecard answers how the pair behaved, while the dossier also answers whether it counted and what it changed
- it is broader than certification alone: certification answers whether the pair counts, while the dossier also answers what changed in the gap, gate, and planner because of it
- it is broader than the next-live planner alone: the planner answers the current gap and next objective, while the dossier answers whether the latest session moved that state or left it unchanged
- `what changed because of this session?` is the concise delta block. Read it as evidence accounting first, not as a mood summary
- rehearsal, synthetic, no-human, weak-signal, and otherwise non-grounded sessions may leave the dossier in a no-impact state. That means the real promotion gap did not move

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\build_latest_session_outcome_dossier.ps1
powershell -NoProfile -File .\scripts\build_latest_session_outcome_dossier.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
```

Or with the thin wrapper:

```bat
scripts\build_latest_session_outcome_dossier.bat
scripts\build_latest_session_outcome_dossier.bat .\lab\logs\eval\pairs\<pair-pack>
```

## Next Live Session Planner

Use `scripts\plan_next_live_session.ps1` when you need the explicit promotion gap instead of only the current gate verdict.

- it writes `next_live_plan.json` and `next_live_plan.md` under `lab\logs\eval\registry\`
- it reuses the existing registry summary, profile recommendation, and responsive gate outputs instead of creating a separate decision engine
- it computes all promotion counts from certified grounded evidence only
- synthetic, rehearsal, workflow-validation-only, weak-signal, insufficient-data, and other non-certified live sessions still appear in the explanation, but they do not reduce the real responsive-promotion gap
- it formalizes the gap fields for grounded conservative sessions, grounded conservative too-quiet sessions, distinct grounded too-quiet pair IDs, strong-signal keep-conservative thresholds, and responsive too-reactive blockers
- it emits a concrete next-session objective instead of only a yes/no gate answer
- it emits a session target block for the next live run: profile, unchanged no-AI control lane, minimum human presence, minimum patch-while-human-present events, minimum post-patch observation window, whether the session can reduce the gap, whether it could open responsive if successful, and whether another conservative session would still be required afterward

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\plan_next_live_session.ps1
```

Or with the thin wrapper:

```bat
scripts\plan_next_live_session.bat
```

Read the stack like this:

- certification decides whether one pair counts toward promotion
- scorecard decides how one captured pair behaved
- registry summary decides the accumulated conservative-vs-responsive recommendation
- responsive gate decides whether the first live responsive trial is open right now
- next-live planner decides what evidence is still missing and what the next real session should try to prove

Here, "evidence gap" means the configured threshold minus the current certified grounded count for that evidence type. Before the next conservative live session, read `next_live_plan.md` so the operator knows whether the goal is first grounded certification, another grounded conservative session, repeated grounded too-quiet evidence, or manual review.

## Next Live Session Mission Brief

Use `scripts\prepare_next_live_session_mission.ps1` after the planner and before the next real live run when you need the single operator-facing answer to "what exact target must the next session hit?"

- it writes `next_live_session_mission.json` and `next_live_session_mission.md` under `lab\logs\eval\registry\`
- it now also carries launcher defaults that `scripts\run_current_live_mission.ps1` uses for drift comparison
- it reads the current responsive gate, the current next-live planner output, and the latest available live outcome dossier when one exists
- it stays thin: the planner still owns the gap math, the gate still owns responsive go/no-go, and the mission helper only turns that current state into a concrete next-session brief
- it is narrower than the planner: the planner explains the full gap, while the mission brief spells out the exact thresholds, exact stop condition, exact failure conditions, and exact grounded-session success requirements for the next run
- it is different from the outcome dossier: the dossier is post-run and explains what changed after the latest session, while the mission brief is pre-run and explains what the next session must accomplish before it starts
- it remains conservative until grounded evidence exists, even if the latest non-grounded live run or rehearsal looked promising
- it ties directly to the live monitor: the mission stop condition is still the existing `sufficient-for-tuning-usable-review` or `sufficient-for-scorecard` verdict, not a new mission-only threshold

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\prepare_next_live_session_mission.ps1
```

Or with the thin wrapper:

```bat
scripts\prepare_next_live_session_mission.bat
```

## Mission-Driven Launch

Use `scripts\run_current_live_mission.ps1` when you want the next live session to launch from the saved mission by default instead of manually re-entering the launch shape.

- it reads `lab\logs\eval\registry\next_live_session_mission.json` by default, or accepts `-MissionPath` for a specific saved brief
- it launches the existing `scripts\run_guided_live_pair_session.ps1` workflow instead of introducing a second pair-runner stack
- it writes preview `mission_execution.json` / `.md` artifacts in dry-run mode and writes final `guided_session\mission_execution.json` / `.md` artifacts when a real or rehearsal-backed session starts
- it records drift for map, bot count, bot skill, control port, treatment port, treatment profile, human-signal thresholds, patch-while-human-present target, post-patch observation target, skip flags, and output roots
- output-root drift is allowed by default because it does not change the experiment meaning; safe port drift requires `-AllowSafePortOverride`
- mission-changing drift such as changing map, bot count, bot skill, treatment profile, or weakening the thresholds is blocked unless `-AllowMissionOverride` is supplied
- if the mission still says `conservative` and the responsive gate is closed, switching to `responsive` is blocked by default; even when explicitly allowed, the run stays mission-divergent and later closeout will say so
- `-DryRun` and `-PrintCommandOnly` do not start a session; they print the mission path, exact launch parameters, exact guided-runner command, and whether drift would be blocked, warned, or allowed

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1 -DryRun
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1 -DryRun -ControlPort 27018 -TreatmentPort 27019 -AllowSafePortOverride
```

## Mission Attainment

Use `scripts\evaluate_latest_session_mission.ps1` after the run when the operator needs the direct closeout answer to "did this session actually accomplish the mission we launched it for?"

- it writes `mission_attainment.json` and `mission_attainment.md` into the pair root
- it reads the saved mission snapshot from `guided_session\mission\` when present, or fails clearly if the pair predates mission snapshots
- it stays thin: the mission helper reuses the mission brief, mission execution record, live monitor, scorecard, grounded certification, outcome dossier, and latest-session delta outputs instead of duplicating their logic
- it is different from the mission brief: the mission brief is the pre-run target, while mission attainment is the post-run answer against that exact saved target
- it is different from the live monitor: the live monitor answers when to stop safely during capture, while mission attainment compares the mission targets against final captured actuals after capture is complete
- it is different from the outcome dossier: the dossier is the broader post-run consolidation view, while mission attainment is the narrower target-by-target mission closeout
- `mission-divergent-run` means the operator explicitly launched something other than the saved mission, so the session must not be treated as a mission-perfect run
- read each `target_results` entry literally: `target_value`, `actual_value`, `met`, and `explanation`
- `mission-met-but-no-promotion-impact` means the run cleared the monitor-facing thresholds but did not move the real promotion ledger
- `mission-met-and-gap-reduced` means the run counted as grounded evidence and reduced a real promotion-gap component while the next objective stayed the same
- `mission-met-and-next-objective-advanced` means the run counted as grounded evidence and changed the next objective, responsive gate, or both
- rehearsal, synthetic, no-human, insufficient-data, weak-signal, and otherwise non-grounded sessions must still fail mission attainment in the promotion sense even if the workflow itself completed cleanly

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\evaluate_latest_session_mission.ps1
powershell -NoProfile -File .\scripts\evaluate_latest_session_mission.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
```

Or with the thin wrapper:

```bat
scripts\evaluate_latest_session_mission.bat
scripts\evaluate_latest_session_mission.bat .\lab\logs\eval\pairs\<pair-pack>
```

## Responsive Trial Gate

Use `scripts\evaluate_responsive_trial_gate.ps1` when you need an explicit go/no-go verdict for the first real live `responsive` treatment session.

- it writes `responsive_trial_gate.json`, `responsive_trial_gate.md`, `responsive_trial_plan.json`, and `responsive_trial_plan.md` under `lab\logs\eval\registry\`
- it reads the registry first and reuses the latest `registry_summary.json` / `profile_recommendation.json` when they already exist
- the thresholds live in `ai_director\testdata\responsive_trial_gate.json` so the promotion rule is explicit and inspectable
- it uses certified grounded evidence only. Registered sessions that fail certification are still explained in the gate output, but they do not count toward thresholds.
- rehearsal, synthetic, no-human, plumbing-valid-only, comparison-insufficient-data, insufficient-data, weak-signal, and validation-only sessions must never unlock the live responsive trial
- repeated certified grounded conservative-too-quiet evidence across distinct pair runs may unlock one bounded responsive trial
- grounded responsive-too-reactive evidence closes the gate and recommends reverting to conservative
- ambiguous grounded evidence remains `manual-review-needed`

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\evaluate_responsive_trial_gate.ps1
```

Interpret the gate action like this:

- `responsive-trial-not-allowed`: the live gate is closed because the evidence is still insufficient, weak, or synthetic-only
- `collect-more-conservative-evidence`: more real grounded conservative evidence is needed before responsive can be considered
- `keep-conservative`: the real grounded conservative evidence already looks acceptable, so responsive should remain blocked
- `responsive-trial-allowed`: one bounded live responsive trial is justified and the generated plan becomes the operator runbook
- `responsive-revert-recommended`: grounded responsive evidence already shows overreaction, so the next live profile should move back to conservative
- `manual-review-needed`: the grounded evidence conflicts or still carries risk that needs an operator read

If the gate is blocked, `responsive_trial_plan.md` is a "not yet" explanation. If the gate is open, `responsive_trial_plan.md` carries the exact live command, minimum human-signal requirement, success criteria, rollback rule, and post-run workflow.

Use the planner before the gate when you need to make the next conservative session purposeful. Use the gate after that when you need the final go/no-go verdict on a responsive trial.

Treat the first real human pair session like an operator checklist, not a tuning experiment. `docs\operator-checklist.md` is the concise runbook for:

- prerequisites
- default control and treatment ports
- what counts as insufficient-data
- what counts as usable-signal
- what to do if no humans join
- what to do if treatment never patches while humans are present

`docs\first-live-pair-notes-template.md` is an optional lightweight scratchpad if an operator wants to jot down who joined, how long they stayed, and whether treatment felt too quiet or too reactive.

Preflight verdicts mean:

- `ready-for-human-pair-session`: required scripts, build output, ports, and profile selection are ready without current warnings
- `ready-with-warnings`: the pair can be run, but at least one non-blocking prerequisite or optional helper still needs attention
- `blocked`: do not spend a human session yet; fix the reported blockers first

Run the replay/scenario tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\common.ps1; `$pythonExe = Get-PythonPath -PreferredPath ''; & `$pythonExe -m unittest ai_director.tests.test_decision ai_director.tests.test_replay_scenarios ai_director.tests.test_tuning_profiles"
```

Use the replay scenarios first when tuning thresholds or hysteresis. They are deterministic, do not require a live server, and now cover one-human dominance, one-human struggles, sparse joins, late joins, threshold-sensitive lanes, oscillation-prone alternation, spike-and-stabilize patterns, overcorrection risk, and close games where AI should remain conservative.

## Synthetic Pair-Session Fixtures

Synthetic pair/session fixtures now live under `ai_director\testdata\pair_sessions\`. They are deterministic, clearly marked as synthetic, and shaped like real pair packs so the post-run tooling can consume them without a separate compatibility layer.

Use them to validate the post-run decision workflow before spending another human-rich session:

- `no_humans_insufficient_data`: both lanes stay plumbing-valid only
- `sparse_humans_weak_signal`: at least one lane stays too sparse for an honest comparison
- `conservative_acceptable_usable_signal`: conservative earns usable grounded evidence and should be repeated, not promoted
- `strong_signal_keep_conservative`: conservative produces the clearest keep-conservative evidence
- `conservative_too_quiet_responsive_candidate`: conservative stays too quiet under grounded signal and responsive becomes the next candidate
- `responsive_too_reactive_revert_candidate`: responsive overreacts and should be reverted to conservative
- `ambiguous_manual_review_needed`: the evidence stays grounded but still needs an operator read instead of blind promotion

These fixtures do not replace real human evidence. They exist to prove that the workflow stays honest about insufficient-data, weak-signal, keep-conservative, conservative-too-quiet responsive-candidate, responsive-too-reactive revert-to-conservative, and manual-review branches before the next live session.

The same rule applies to the responsive-trial gate: synthetic fixtures can exercise the gate logic in validation mode, but synthetic-only evidence must never unlock the real live gate by itself.

Regenerate the synthetic pair packs if the deterministic source definitions change:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\common.ps1; `$pythonExe = Get-PythonPath -PreferredPath ''; & `$pythonExe .\scripts\generate_pair_session_fixtures.py"
```

Run the fixture-backed decision tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\common.ps1; `$pythonExe = Get-PythonPath -PreferredPath ''; & `$pythonExe -m unittest ai_director.tests.test_pair_session_fixtures"
```

Run the optional compact fixture demo:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_fixture_decision_demo.ps1
```

The demo copies the synthetic pair packs into a scratch evaluation root, runs shadow review, scores every pair, certifies them, registers them into a synthetic registry, and emits a compact branch summary. Treat that output as workflow validation only, never as a substitute for real live human evidence.

Run the latest-session delta validation helper when you need fixture-backed coverage for the new post-session analysis layer:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate_grounded_session_delta.ps1
```

That helper validates the non-grounded branch against the current live registry and validates grounded positive, grounded too-quiet, grounded strong-signal, and responsive-blocker delta paths with test-only copied fixture packs in an isolated scratch registry.

When the specific goal is guided-workflow sufficiency rehearsal instead of broad fixture coverage, prefer `scripts\run_guided_live_pair_session.ps1 -RehearsalMode ...`. That path exercises the real guided monitor, auto-stop, docket, certification, and post-run orchestration on a labeled rehearsal pair root, keeps the resulting registry under `guided_session\registry\`, and must still leave the responsive gate closed.

If a local Half-Life client is installed, you can resolve or dry-run the join command with:

```powershell
powershell -NoProfile -File .\scripts\launch_local_hldm_client.ps1 -Port 27017 -DryRun
```

If `hl.exe` is not present, the helper fails with a precise prereq message telling you to pass `-ClientExePath` or set `HL_CLIENT_EXE`.

## Bot Test Config

The checked-in template lives at `addons\jk_botti\test_bots.cfg`.

Each launcher run materializes a map-specific `lab\hlds\valve\addons\jk_botti\jk_botti_<map>.cfg` that:

- sets `botskill` to the requested skill,
- pins `min_bots` and `max_bots` to the requested bot count,
- emits the same number of `addbot "" "" <skill>` lines for deterministic startup,
- keeps the AI balance bridge enabled,
- disables chat/logo randomness to keep the local test stand more repeatable.

The no-AI baseline launcher generates the same `jk_botti_<map>.cfg` filename directly from the manual crossfire baseline. It preserves:

- `pause 3`
- `autowaypoint 1`
- `bot_add_level_tag 1`
- `bot_conntimes 0`
- `team_balancetype 1`
- all chat, taunt, whine, endgame, logo, and color randomness disabled
- `bot_shoot_breakables 2`
- `jk_ai_balance_enabled 0`

Only `botskill`, `min_bots`, `max_bots`, and the matching `addbot` lines change when the requested bot count or skill differs from the default baseline.

For evaluation runs the no-AI control lane still keeps `jk_ai_balance_enabled 0` and never starts the sidecar, but the plugin now emits read-only telemetry snapshots into per-match history so the control lane can be compared with the treatment lane without enabling balance changes.

The earlier `unknown command: 'jk_ai_balance_enabled 0'` startup line came from JK Botti's config parser treating registered cvars as unknown before forwarding them to the engine. The launcher no longer emits that avoidable warning because registered cvars are now passed through cleanly without being mislabeled.

## Sidecar Configuration

The sidecar can be configured through environment variables or `.env` files loaded from either:

- `.\ai_director\.env`
- `.\.env`

Supported values:

- `OPENAI_API_KEY`: optional; if omitted, fallback rules are used.
- `OPENAI_MODEL`: optional; defaults to `gpt-4o-mini`.
- `AI_DIRECTOR_POLL_INTERVAL`: optional; defaults to `5`.
- `AI_DIRECTOR_LOG_LEVEL`: optional; defaults to `INFO`.
- `AI_DIRECTOR_TUNING_PROFILE`: optional; defaults to `default`.

If `OPENAI_API_KEY` is absent, the launcher stays in offline fallback mode and the Python sidecar uses the deterministic rules engine. To switch to OpenAI mode later, set `OPENAI_API_KEY` in `.env` or the environment and rerun the same launcher.

## Tuning Profiles

A tuning profile is a named bundle of bounded offline rule parameters for the AI sidecar and the replay evaluator. The current catalog lives in `ai_director\testdata\tuning_profiles.json`.

- `conservative`: more signal required before the lane is judged usable, slower cooldown, and more caution near the threshold.
- `default`: current bounded baseline behavior and the reference profile for regression checks.
- `responsive`: lower thresholds and shorter cooldown for earlier response to sustained imbalance.

When you pass `-TuningProfile` into `scripts\run_balance_eval.ps1`, `scripts\run_mixed_balance_eval.ps1`, or `scripts\run_ai_director.ps1`, the chosen profile name and effective knobs are recorded in `lane.json`, `summary.json`, `summary.md`, and the session pack. The no-AI control lane remains profile-agnostic and still serves as the sidecar-free control.

Read the replay sweep outputs like this:

- `summary.json` / `summary.md`: per-profile boundedness, cooldown, churn, oscillation, underactivity, and accepted-scenario counts
- `comparison.json` / `comparison.md`: safest profile, most conservative profile, most responsive profile, best oscillation avoidance, best underreaction avoidance, and the next live candidate

Use the replay sweep first to choose the next treatment profile, then capture a live AI lane with the same `-TuningProfile` value and compare it against the no-AI control lane.

## Smoke Test Expectations

`scripts/smoke_test.ps1` first verifies that:

- both launcher entry points exist,
- `addons/jk_botti/test_bots.cfg` exists,
- the generated `jk_botti_<map>.cfg` matches the requested bot count and skill,
- the staged `jk_botti_mm.dll` exists,
- `plugins.ini` exists and points at `addons/jk_botti/dlls/jk_botti_mm.dll`.

The script then classifies the running lab into attach/load states instead of only timing out on a missing patch:

- `hlds-did-not-start`
- `metamod-did-not-load`
- `plugin-dll-file-missing`
- `plugin-dll-load-failed`
- `plugin-dll-loaded-but-meta-query-not-reached`
- `plugin-loaded-but-meta-query-failed`
- `plugin-passed-meta-query-but-did-not-attach`
- `plugin-attached-but-bootstrap-log-missing`
- `plugin-attached-but-config-warning-present`
- `plugin-attached-but-no-telemetry`
- `telemetry-emitted-but-no-patch-path-yet`
- `telemetry-and-patch-emitted-but-no-apply-log-yet`
- `ai-sidecar-not-yet-running`
- `no-ai-path-active-but-sidecar-running`
- `no-ai-path-active-but-unexpected-patch-output`
- `no-ai-healthy`
- `ai-healthy`

`-Mode NoAI` treats `jk_ai_balance_enabled 0` as intentional and returns `no-ai-healthy` once attach succeeds, the bootstrap log exists, no sidecar process is running, no patch path is present, and the avoidable config warning is absent. `-Mode AI` still performs the bounded fallback director validation and expects `ai-healthy`, which requires attach success, bootstrap logging, a running sidecar, telemetry output, patch output, and an `[ai_balance] applied patch=` line.

If HLDS or Metamod was not installed yet, or the server was not started, the smoke test will report the narrowest observed status and include HLDS/bootstrap log tails.

## Balance Evaluation Artifacts

Each lane written by `scripts\run_balance_eval.ps1` gets its own folder under `lab\logs\eval\`.

The control lane is the baseline:

- launcher path: `scripts\run_standard_bots_crossfire.bat`
- default map: `crossfire`
- default bot count: `4`
- default bot skill: `3`
- `jk_ai_balance_enabled 0`
- no Python sidecar

The treatment lane reuses `scripts\run_test_stand_with_bots.ps1` and adds sidecar-driven patch history.

Each pair written by `scripts\run_control_treatment_pair.ps1` gets its own folder under `lab\logs\eval\pairs\`.

The pair root preserves:

- nested control lane artifacts
- nested treatment lane artifacts
- `pair_summary.json`
- `pair_summary.md`
- `comparison.json`
- `comparison.md`
- `control_join_instructions.txt`
- `treatment_join_instructions.txt`
- `pair_join_instructions.txt`
- `shadow_review\shadow_profiles.json`
- `shadow_review\shadow_profiles.md`
- `shadow_review\shadow_recommendation.json`
- `shadow_review\shadow_recommendation.md`

The lane manifest and summaries now distinguish:

- plumbing-healthy: launcher, attach, telemetry, and patch plumbing worked
- tuning-usable: enough human signal existed to judge live rebalancing
- insufficient-data: live signal was absent or too sparse to trust for tuning

Each lane folder contains:

- copied HLDS logs
- copied sidecar logs when AI mode is used
- copied bootstrap log
- copied generated bot config
- `latest.telemetry.json`
- `latest.patch.json` for AI mode
- `telemetry_history.ndjson`
- `patch_history.ndjson` for AI mode
- `patch_apply_history.ndjson` for AI mode
- `bot_settings_history.ndjson` for AI mode
- `lane.json`
- `summary.json`
- `summary.md`
- `session_pack.json`
- `session_pack.md`
- `join_instructions.txt`
- `human_presence_timeline.ndjson`

Per-lane summaries now include:

- lane label
- human snapshots count
- seconds with human presence
- first and last human seen offsets
- patch events and patch applies while humans were present
- frag-gap samples while humans were present
- rebalance opportunities and post-patch observation windows
- lane-quality verdict
- evidence-quality verdict
- stability verdict
- explanation string
- whether the mixed-session wait timed out before enough human signal existed

Read the pair artifacts in this order:

- `scorecard.md`: concise operator-facing decision report for the pair, including the treatment assessment and explicit next-action recommendation
- `pair_summary.md`: operator-facing answer to whether the run was only plumbing-valid, partially usable, tuning-usable, or strong-signal
- `comparison.md`: grounded pair metrics such as both lane verdicts, both evidence-quality labels, whether treatment patched while humans were present, whether a meaningful post-patch observation window existed, frag-gap samples while humans were present, and the conservative explanation string
- lane `session_pack.md`: the per-lane context if you need to drill into one side of the pair

## Summary Verdicts

- `stable`: bounded actions, limited reversals, and recent telemetry near equilibrium.
- `underactive`: strong frag-gap momentum with too little corrective action.
- `oscillatory`: repeated flips between stronger and weaker settings.
- `insufficient-data`: not enough telemetry to decide.

The summary reports also call out whether cooldown and boundedness constraints were respected, how many telemetry snapshots and patch events were seen, and whether the control-vs-treatment pair is usable for tuning.

Lane quality is reported separately from the stability verdict:

- `ai-healthy-no-humans`: the AI lane was plumbing-healthy, but no humans were present
- `ai-healthy-human-sparse`: humans joined, but not long enough to judge rebalancing
- `ai-healthy-human-usable`: enough human signal existed for a real tuning sample
- `ai-healthy-human-rich`: stronger mixed-session sample with longer or denser human presence

Evidence quality is also reported separately:

- `insufficient-data`: no grounded treatment evidence exists yet
- `weak-signal`: humans were present, but post-patch evidence stayed weak
- `usable-signal`: at least one grounded post-patch observation window exists
- `strong-signal`: multiple grounded post-patch observation windows exist

Pair/operator verdicts are reported separately:

- `plumbing-valid only`: both launch paths worked, but neither lane captured enough human signal to justify tuning claims
- `partially usable`: one lane was informative or treatment hinted at something, but the pair is not yet fair enough for a strong comparison
- `tuning-usable`: both lanes were human-usable and treatment produced at least one grounded post-patch observation window
- `strong-signal`: both lanes were human-usable and treatment produced multiple grounded post-patch windows

Pair comparison verdicts are also preserved in `comparison.json` / `comparison.md`:

- `comparison-insufficient-data`
- `comparison-weak-signal`
- `comparison-usable`
- `comparison-strong-signal`

The first-human-session scorecard adds one more operator-focused treatment label:

- `too quiet`: humans were present long enough to compare lanes, and conservative still looked too quiet relative to control under grounded live evidence
- `appropriately conservative`: conservative produced grounded human-present patch evidence without looking overactive
- `inconclusive`: human presence, patch timing, or post-patch windows were still too weak to justify a profile decision
- `too reactive`: the treatment lane looked oscillatory or violated a guardrail and needs manual artifact review

Use the scorecard recommendations like this:

- `keep-conservative-and-collect-more`: conservative remains the next live default
- `treatment-evidence-promising-repeat-conservative`: repeat conservative before changing profile
- `weak-signal-repeat-session`: collect another conservative session because live evidence stayed weak
- `conservative-looks-too-quiet-try-responsive-next`: responsive is justified as the next candidate only because conservative stayed too quiet under usable human presence
- `responsive-too-reactive-revert-to-conservative`: grounded responsive evidence already says the live treatment overreacted, so the next live profile should move back to conservative
- `insufficient-data-repeat-session`: reject the session as tuning evidence
- `manual-review-needed`: inspect `comparison.md`, `scorecard.md`, and the treatment lane summary before choosing the next action

## Attach Troubleshooting

- Check `lab\hlds\valve\addons\metamod\plugins.ini`. It should contain `win32 addons/jk_botti/dlls/jk_botti_mm.dll`.
- Check the deployed plugin path with `powershell -NoProfile -File .\scripts\inspect_plugin_path.ps1`.
- Check x86 vs x64 and the export table with `powershell -NoProfile -File .\scripts\inspect_plugin_exports.ps1`. The Release lab DLL should report `14C machine (x86)` / `PE32`.
- Check runtime dependencies with `powershell -NoProfile -File .\scripts\inspect_plugin_dependencies.ps1`. `Release|Win32` uses `MultiThreaded` (`/MT`) and should not require the VC++ redistributable in the lab.
- Check the earliest bootstrap log at `lab\hlds\valve\addons\jk_botti\runtime\bootstrap.log`.
- Use `scripts\run_standard_bots_crossfire.bat` first when debugging attach. It keeps the startup path narrowed to HLDS, Metamod, and the jk_botti DLL.
- If you still see an `unknown command: 'jk_ai_balance_*'` line in HLDS stdout, treat it as a regression in config-command classification rather than a Metamod attach failure. A healthy launcher run should not emit that warning.

## Operational Notes

- The scripts are written for Win32 HLDS and should not be switched to x64.
- Runtime JSON files are rewritten atomically to reduce partial read/write races.
- The plugin applies only bounded patch values and ignores repeated or stale patches.
- Generated downloads, logs, and binaries live under ignored paths and should not be committed.
