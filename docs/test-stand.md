# HLDM Test Stand

PROMPT_ID_BEGIN
HLDM-JKBOTTI-AI-STAND-20260415-71
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

The new product-minimum public launcher is for a public-facing `crossfire` server with bots only while no humans are present:

```bat
scripts\run_public_crossfire_server.bat
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
scripts\run_public_crossfire_server.bat -Map crossfire -BotCountWhenEmpty 4 -BotSkillWhenEmpty 3 -Port 27015 -SkipSteamCmdUpdate -SkipMetamodDownload
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

`scripts\run_public_crossfire_server.ps1` is separate from both lab launchers. It still reuses the healthy HLDS + Metamod + jk_botti path, but it is meant for product-minimum public operation instead of control/treatment capture:

1. `scripts\build_vs2022.ps1`
2. `scripts\setup_test_stand.ps1`
3. writes a public `server.cfg` with `sv_lan 0`, a generated RCON password, and no research-only runtime requirements
4. writes `jk_botti_<map>.cfg` from `addons\jk_botti\public_crossfire.cfg`
5. starts HLDS through `scripts\run_server.ps1`
6. monitors authoritative human count from GoldSrc `status` over RCON and applies the public bot policy

## Public Crossfire Mode

Start the product-minimum public server like this:

```powershell
powershell -NoProfile -File .\scripts\run_public_crossfire_server.ps1 -Map crossfire -BotCountWhenEmpty 4 -BotSkillWhenEmpty 3 -Port 27015 -SkipSteamCmdUpdate -SkipMetamodDownload
```

The public-mode bot policy is intentionally narrow:

- when no real humans are present, set `jk_botti min_bots` and `max_bots` to the configured empty-server target so the server is not empty
- when one or more real humans are present, set the target to `0`, issue `jk_botti kickall`, and keep bots out while humans remain
- when the server becomes empty again, wait the bounded repopulate delay and restore the configured target

The public runner reports one clear policy state at a time:

- `waiting-human-join-grace`
- `waiting-empty-server-repopulate`
- `bots-active-empty-server`
- `bots-disconnected-humans-present`

The public runner writes status artifacts under `lab\logs\public_server\...`:

- `public_server_status.json`
- `public_server_status.md`

These files are the operator-facing source of truth for public mode. They include the map, port, join targets, human count, bot count, current commanded bot target, last policy action, and whether advanced AI balance is enabled.

Launch one explicit local public admission attempt like this:

```powershell
powershell -NoProfile -File .\scripts\launch_public_hldm_client.ps1 -ServerAddress 127.0.0.1 -ServerPort 27015 -PublicServerOutputRoot D:\DEV\CPP\HL-Bots\lab\logs\public_server\<run-root> -UseSteamLaunchPath
```

This helper is public-mode specific. It prefers the Steam-native `sv_lan 0` admission path, keeps a direct `hl.exe` comparison path available, and writes:

- `public_client_admission_attempt.json`
- `public_client_admission_attempt.md`

These artifacts preserve the exact command, working directory, launcher PID, new client PID list, Steam log path, `qconsole.log` path, server log path, and whether authoritative server admission actually happened.

Diagnose one failed public admission attempt like this:

```powershell
powershell -NoProfile -File .\scripts\diagnose_public_client_admission.ps1 -AttemptJsonPath D:\DEV\CPP\HL-Bots\lab\logs\public_server\client_admissions\<attempt-root>\public_client_admission_attempt.json
```

The diagnosis helper writes:

- `public_client_admission_diagnosis.json`
- `public_client_admission_diagnosis.md`

Unlike `scripts\join_live_pair_lane.ps1`, these helpers are not for control/treatment lane work. They are specifically for public-mode client admission and only report success after the server sees a real human connect or `entered the game`.

Validate the public human-trigger path like this:

```powershell
powershell -NoProfile -File .\scripts\validate_public_human_trigger.ps1 -Map crossfire -BotCountWhenEmpty 4 -BotSkillWhenEmpty 3 -Port 27015 -SkipSteamCmdUpdate -SkipMetamodDownload
```

The validator reuses the same authoritative human-count source as public mode itself: GoldSrc `status` over RCON. It writes:

- `public_human_trigger_validation.json`
- `public_human_trigger_validation.md`

The validator records whether these public states were actually observed:

- `waiting-human-join-grace`
- `bots-active-empty-server`
- `bots-disconnected-humans-present`
- `waiting-empty-server-repopulate`
- `bots-repopulated-empty-server`

The validator also records which admission path was attempted, whether it fell back from Steam-native to direct `hl.exe`, and the matching `public_client_admission_diagnosis.json` path for each attempt.

If a local public join still fails before real server admission, the validator preserves the exact blocker with the latest public status snapshot, the public admission diagnosis, `qconsole.log` tail, and Steam `connection_log_<port>.txt` tail instead of pretending the human-trigger path was fully exercised.

Advanced AI / LLM-based learning remains present in the repository, but public mode keeps it off by default. Use `-EnableAdvancedAIBalance` only when you intentionally want to opt back into the sidecar-backed path later.

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
- it writes `guided_session\session_state.json`, `guided_session\final_session_docket.json`, and `guided_session\final_session_docket.md` under the pair root after the run, and that docket points to the pre-run mission brief, the mission execution record, the post-run outcome dossier, and the mission-attainment closeout
- in rehearsal mode it writes an isolated validation-only registry under `guided_session\registry\` so real live ledgers stay untouched
- if the planner later says `manual-review-before-next-session`, run `scripts\review_counted_pair_evidence.ps1` on the flagged pair root before another live conservative attempt
- if that counted-pair review keeps the pair counted but exact treatment-side or monitor-derived metrics still disagree, run `scripts\reconcile_pair_metrics.ps1 -PairRoot <pair-root> -DryRun` first and rerun with `-ExecuteRefresh` only when the report says promotion state stays unchanged and the refresh is limited to secondary artifacts

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
12. If the dossier, mission-attainment closeout, or planner says `manual-review-before-next-session`, stop and run `powershell -NoProfile -File .\scripts\review_counted_pair_evidence.ps1 -PairRoot <pair-root>` before another live spend.
13. If that review keeps the pair counted but exact treatment-side or monitor-derived metrics still disagree, run `powershell -NoProfile -File .\scripts\reconcile_pair_metrics.ps1 -PairRoot <pair-root> -DryRun`.
14. Use `-ExecuteRefresh` only when the reconciliation report says the refresh is safe, auditable, and limited to secondary artifacts such as the switch gate, treatment gate, phase flow, live monitor snapshot, mission closeout, or outcome dossier.

Use rehearsal mode for workflow validation only:

- it should progress through `waiting-for-control-human-signal`, `waiting-for-treatment-human-signal`, `waiting-for-treatment-patch-while-humans-present`, `waiting-for-post-patch-observation-window`, and `sufficient-for-tuning-usable-review`
- with `-AutoStopWhenSufficient`, the guided runner should request stop only after the sufficient verdict appears
- after the rehearsal pair finalizes, the last monitor verdict should become `sufficient-for-scorecard`
- the saved pair pack, scorecard, final docket, certificate, and rehearsal registry should all make the synthetic rehearsal labeling explicit
- `grounded_evidence_certificate.json` and `.md` should say the rehearsal pack is excluded from promotion and counts only as workflow validation
- rehearsal success proves the workflow branch works; it does not prove the live tuning is good

## Counted Pair Review

When a historically counted pair root contains contradictory monitor, gate, certification, or wrapper narratives, run:

```powershell
powershell -NoProfile -File .\scripts\review_counted_pair_evidence.ps1 -PairRoot .\lab\logs\eval\<pair-root>
```

The helper keeps evidence precedence explicit:

- authoritative: `pair_summary.json`, lane `summary.json`, `patch_apply_history.ndjson`, `patch_history.ndjson`, mission snapshot/execution, saved gate outputs, saved monitor state/history, and `grounded_evidence_certificate.json`
- potentially stale narrative outputs: `mission_attainment.json`, wrapped milestone reports, older markdown summaries, and inherited explanation strings

If the counted status stays true but exact treatment-side or monitor-derived metrics still disagree, run:

```powershell
powershell -NoProfile -File .\scripts\reconcile_pair_metrics.ps1 -PairRoot .\lab\logs\eval\<pair-root> -DryRun
powershell -NoProfile -File .\scripts\reconcile_pair_metrics.ps1 -PairRoot .\lab\logs\eval\<pair-root> -ExecuteRefresh
```

Metric reconciliation is narrower than counted-pair review:

- canonical evidence: `pair_summary.json`, lane `summary.json`, `patch_history.ndjson`, `patch_apply_history.ndjson`, telemetry history, mission snapshot/execution, and `grounded_evidence_certificate.json`
- secondary artifacts: `treatment_patch_window.json`, `control_to_treatment_switch.json`, `conservative_phase_flow.json`, `live_monitor_status.json`, `mission_attainment.json`, the outcome dossier, and wrapped milestone reports
- safe refresh may rebuild only those secondary artifacts; it must not silently rewrite raw evidence, append-only registry history, or promotion thresholds

If reconciliation succeeds and only stale wrapper wording remains, run:

```powershell
powershell -NoProfile -File .\scripts\refresh_pair_wrapper_narratives.ps1 -PairRoot .\lab\logs\eval\<pair-root>
```

That helper is narrower than reconciliation:

- it regenerates only secondary wrappers such as `human_participation_conservative_attempt.json` and `guided_session\final_session_docket.json`
- it reuses canonical pair evidence plus the accepted reconciliation output instead of rereading stale wrapper narratives
- it writes `wrapper_refresh_report.json` / `.md` and `counted_pair_clearance.json` / `.md`
- it may clear a pair-level manual-review label only when canonical evidence, refreshed wrappers, and the unchanged promotion/gate state all remain consistent
- it must not silently change registry inclusion, grounded counting, responsive-gate state, or the next-live objective

If the pair-level manual-review label is cleared but the global gate/planner still looks manual-review-oriented, run:

```powershell
powershell -NoProfile -File .\scripts\recompute_after_pair_clearance.ps1 -PairRoot .\lab\logs\eval\<pair-root>
```

Post-clearance recompute differs from the earlier helpers:

- counted-pair review asks whether the pair should still count at all
- metric reconciliation settles canonical counts and safe secondary refresh
- wrapper refresh fixes stale wrapper narratives and may clear the pair-level manual-review label
- post-clearance recompute reruns downstream decision artifacts from an additive clearance-aware overlay so you can compare before vs after responsive-gate and next-objective state without rewriting append-only registry history

If pair-level cleanup is done but the global state still says `manual-review-needed` or `manual-review-before-next-session`, run:

```powershell
powershell -NoProfile -File .\scripts\review_grounded_evidence_matrix.ps1
```

This helper is global rather than pair-local:

- it reads the counted grounded conservative sessions from the registry
- it builds one explicit matrix of the sessions that currently count toward promotion
- it shows which grounded sessions look appropriately conservative and which look too quiet
- it compares that matrix with the current responsive gate and next-live objective
- it explains whether the manual-review state is genuinely warranted or only appears stale

If that matrix says the global state is genuinely mixed and there are still zero counted grounded strong-signal conservative sessions, prepare the stronger disambiguation mission instead of spending another generic grounded run:

```powershell
powershell -NoProfile -File .\scripts\prepare_strong_signal_conservative_mission.ps1
```

Use it like this:

- it keeps `conservative` as the treatment profile and keeps the no-AI control lane unchanged
- it differs from `prepare_next_live_session_mission.ps1`: the normal mission helper mirrors the current planner as-is, while the strong-signal mission helper is an explicit operator choice for the mixed-evidence case
- it raises the control/treatment human-signal targets, treatment patch-while-human-present target, and post-patch observation window above the grounded minimum so the next run is more discriminating
- it writes `strong_signal_conservative_mission.json` / `.md` and prints the exact `run_current_live_mission.ps1`, `run_human_participation_conservative_attempt.ps1`, and `run_next_grounded_conservative_cycle.ps1` commands that can consume that mission through `-MissionPath`
- it still does not open `responsive` automatically and does not change the responsive-gate thresholds

Use the strong-signal conservative mission when the next useful answer is:

- does richer grounded conservative evidence repeat "appropriately conservative" and strengthen the keep-conservative case?
- does richer grounded conservative evidence repeat "too quiet" and strengthen the future responsive case?
- or does the next run still stay ambiguous enough that manual review remains the correct answer?

When you are ready to spend that live run, use the strong-signal conservative attempt wrapper:

```powershell
powershell -NoProfile -File .\scripts\run_strong_signal_conservative_attempt.ps1
```

This wrapper stays thin:

- it reads `strong_signal_conservative_mission.json` by default and keeps the stronger-signal thresholds visible in the saved report
- it reuses the existing client-assisted conservative path instead of creating another launch or closeout engine
- it writes `strong_signal_conservative_attempt.json` / `.md` with the mission path used, pair root, lane verdicts, certification verdict, promotion-counting status, strong-signal before/after counts, grounded before/after counts, responsive gate before/after, next objective before/after, and the before/after evidence mix
- use it only after the repeated bounded join certificate is honestly `ready-for-next-strong-signal-attempt`; bounded green is the prerequisite for the full spend, not proof that the strong-signal session already succeeded
- `first-strong-signal-conservative-capture` is only valid if the pair both counts toward promotion and actually adds grounded strong-signal conservative evidence to the matrix
- unsuccessful results must stay explicit as still-mixed, insufficient-human-signal, interrupted-and-recovered, or manual-review-required; the helper must not treat a merely grounded tuning-usable pair as a strong-signal capture
- a successful strong-signal conservative result strengthens either keep-conservative or the future responsive case depending on the saved treatment-behavior assessment, but it still does not open `responsive` automatically

If the pair remains counted, refresh only safe derived artifacts. If the review recommends registry correction, do that explicitly and auditably instead of silently rewriting promotion history.

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

## Session Recovery Assessment

Use `scripts\assess_latest_session_recovery.ps1` when the question is not "did the mission succeed?" but "is the latest pair complete, interrupted, salvageable, or rerun-only?"

- it writes `session_recovery_report.json` and `session_recovery_report.md` into the assessed pair root
- by default it inspects the latest pair pack; pass `-PairRoot .\lab\logs\eval\pairs\<pair-pack>` for an explicit saved session
- it checks the mission snapshot, mission execution, monitor status, pair summary, comparison, scorecard, shadow review, grounded certificate, latest-session delta, next-live planner output, outcome dossier, mission attainment, final docket, and guided `session_state.json` when present
- when the session is recoverable, it also prints the exact `finalize_interrupted_session.ps1` command instead of leaving the operator to choose post-run helpers manually
- it keeps interrupted-run interpretation conservative: missing or partial closeout artifacts do not silently count as completed evidence, and sessions that never reached sufficiency are told to rerun instead of being over-salvaged
- it is different from mission attainment: mission attainment asks whether the run achieved its saved mission, while recovery assessment asks whether the run finished cleanly enough to trust, salvage, or discard
- it is different from the outcome dossier: the dossier is the completed-session consolidation layer, while recovery assessment is the interruption/recovery layer used before trusting that closeout

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\assess_latest_session_recovery.ps1
powershell -NoProfile -File .\scripts\assess_latest_session_recovery.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
```

Or with the thin wrapper:

```bat
scripts\assess_latest_session_recovery.bat
scripts\assess_latest_session_recovery.bat .\lab\logs\eval\pairs\<pair-pack>
```

## Session Salvage

Use `scripts\finalize_interrupted_session.ps1` only when recovery assessment says the saved pair is recoverable without replaying the live run.

- it writes `session_salvage_report.json` and `session_salvage_report.md` into the pair root
- it can salvage recoverable branches such as `session-interrupted-after-sufficiency-before-closeout`, `session-interrupted-during-post-pipeline`, and `session-partial-artifacts-recoverable`
- it refuses `session-interrupted-before-sufficiency`, `session-nonrecoverable-rerun-required`, `session-manual-review-needed`, and other blocked states instead of pretending those runs can be finalized honestly
- it preserves evidence instead of replaying the session: the helper rebuilds the closeout layer around the saved pair and then re-runs recovery assessment to confirm whether the session is now structurally complete
- a salvaged rehearsal, synthetic, or otherwise non-grounded session may still remain workflow-validation-only and excluded from promotion; salvage completes structure, not promotion eligibility

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\finalize_interrupted_session.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
```

Or with the thin wrapper:

```bat
scripts\finalize_interrupted_session.bat .\lab\logs\eval\pairs\<pair-pack>
```

## Mission Continuation Controller

Use `scripts\continue_current_live_mission.ps1` when you want one operator-safe answer to "should I leave this session alone, salvage it, rerun it, or stop for manual review?"

- it writes `mission_continuation_decision.json` and `mission_continuation_decision.md` into the assessed pair root
- by default it previews the decision only; use `-Execute` only when you want the helper to run the chosen salvage or rerun path
- it reuses `scripts\assess_latest_session_recovery.ps1`, `scripts\finalize_interrupted_session.ps1`, and `scripts\run_current_live_mission.ps1` instead of introducing a second recovery or rerun engine
- it maps complete sessions to no-action or review-only, recoverable interrupted sessions to salvage, pre-sufficiency or nonrecoverable sessions to rerun, and missing or inconsistent mission context to manual review or blocked-no-mission-context
- reruns reuse the saved mission snapshot when available so the new launch stays mission-compliant; if the controller must fall back to the current mission brief, it marks the rerun as mission-recovered instead of pretending the interrupted launch was reproduced exactly
- salvaged and completed rehearsal, synthetic, weak-signal, or otherwise non-grounded sessions still remain excluded from promotion; the controller does not upgrade their evidence bucket
- it is different from recovery assessment alone: recovery tells you what state the saved pair is in, while the continuation controller tells you which supported path to take next and can execute it explicitly
- it is different from salvage alone: salvage can only finalize recoverable sessions, while the continuation controller can also say no-action, rerun, or manual review

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\continue_current_live_mission.ps1 -DryRun
powershell -NoProfile -File .\scripts\continue_current_live_mission.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack> -DryRun
powershell -NoProfile -File .\scripts\continue_current_live_mission.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack> -Execute
```

Or with the thin wrapper:

```bat
scripts\continue_current_live_mission.bat .\lab\logs\eval\pairs\<pair-pack> -DryRun
```

## Continuation Rehearsal

Use `scripts\run_mission_continuation_rehearsal.ps1` when you want a disaster rehearsal that starts from the mission-driven launcher, injects a controlled interruption, runs recovery assessment, lets the continuation controller choose salvage or rerun, and then verifies the resulting artifact state.

- it writes branch-local `continuation_rehearsal_report.json` and `continuation_rehearsal_report.md`, plus suite-level `rehearsal_suite_summary.json` and `rehearsal_suite_summary.md`
- it stays thin: the runner reuses `run_current_live_mission.ps1`, `inject_pair_session_failure.ps1`, `assess_latest_session_recovery.ps1`, `continue_current_live_mission.ps1`, and `finalize_interrupted_session.ps1`
- `inject_pair_session_failure.ps1` is rehearsal-safe by default and stages failure modes such as `already-complete`, `after-sufficiency-before-closeout`, `during-post-pipeline`, `before-sufficiency`, `missing-mission-snapshot`, and optional `partial-artifacts-recoverable`
- the honest expected branches are:
  - already-complete -> no-action or review-only
  - after-sufficiency-before-closeout -> salvage
  - during-post-pipeline -> salvage
  - before-sufficiency -> rerun-current-mission or rerun-current-mission-with-new-pair-root
  - missing-mission-snapshot -> manual-review-required
- success means the final branch report shows the right initial recovery verdict, the right continuation decision, the right downstream action, and a structurally complete result only when salvage or rerun truly finished
- rehearsal success is still workflow validation only. The pair remains `rehearsal`, `synthetic_fixture`, and `validation_only`; certification stays excluded from grounded evidence; the responsive gate stays closed; and registry outputs stay under branch-local rehearsal paths such as `guided_session\registry\`
- this differs from the real live continuation path because it proves failure-policy wiring without claiming grounded live evidence

Run the whole suite or selected branches like this:

```powershell
powershell -NoProfile -File .\scripts\run_mission_continuation_rehearsal.ps1
powershell -NoProfile -File .\scripts\run_mission_continuation_rehearsal.ps1 -FailureModes during-post-pipeline
```

If a completed rehearsal base pair already exists, reuse it to avoid another rehearsal launch:

```powershell
powershell -NoProfile -File .\scripts\run_mission_continuation_rehearsal.ps1 -BasePairRoot .\lab\logs\eval\continuation_rehearsal\<suite>\runtime\<pair-pack> -FailureModes already-complete,before-sufficiency,missing-mission-snapshot
```

Or use the thin wrapper:

```bat
scripts\run_mission_continuation_rehearsal.bat -FailureModes already-complete
```

## Recovery Branch Matrix

Use `scripts\run_recovery_branch_matrix.ps1` when you want the full recovery-policy validation collapsed into one branch matrix plus one operator-facing readiness certificate.

- it covers the required recovery branches end to end: `already-complete`, `after-sufficiency-before-closeout`, `during-post-pipeline`, `partial-artifacts-recoverable`, `before-sufficiency`, and `missing-mission-snapshot`
- it stays thin by reusing the existing rehearsal and continuation stack instead of introducing a new recovery engine
- `recovery_branch_matrix.json` / `.md` record, for each branch, the staged failure mode, expected and actual recovery verdicts, expected and actual continuation decisions, whether salvage or rerun happened, whether the result became structurally complete, and whether promotion exclusion stayed intact
- `recovery_readiness_certificate.json` / `.md` summarize whether the continuation workflow is operationally ready for the first real human-rich conservative session from a failure-handling standpoint
- a ready verdict means the controller stayed conservative, salvaged rehearsal outputs stayed isolated under the branch-local rehearsal registry, rehearsal evidence stayed excluded from promotion, and the responsive gate stayed closed on rehearsal-only evidence
- this is still workflow validation only. Passing the matrix does not create grounded live evidence or justify opening `responsive`

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\run_recovery_branch_matrix.ps1
```

Or with the thin wrapper:

```bat
scripts\run_recovery_branch_matrix.bat
```

Inspect `recovery_readiness_certificate.md` first, then `recovery_branch_matrix.md` if you need the per-branch explanation behind the verdict.

## First Grounded Conservative Attempt

Use `scripts\run_first_grounded_conservative_attempt.ps1` when you are ready to spend the first conservative live attempt that might become the first grounded conservative evidence pack.

- it reuses the existing mission-driven launch path instead of inventing a second runner
- it keeps the treatment profile fixed at `conservative`, keeps the no-AI control lane unchanged, and reuses the live monitor plus the normal post-run closeout stack
- it writes `first_grounded_conservative_attempt.json` and `first_grounded_conservative_attempt.md` so the operator gets one concise answer about whether the attempt captured grounded conservative evidence, reduced the promotion gap, or failed honestly
- if the session ends incomplete, it reuses the continuation controller and salvage flow instead of trying to finalize the run ad hoc
- if there is still no real human-rich signal in the environment, the helper must say so directly and keep the responsive gate unchanged
- this differs from `run_current_live_mission.ps1`: the mission runner launches the session, while the first-grounded helper is the milestone-oriented wrapper that also summarizes certification, grounded deltas, mission attainment, and the before/after evidence state

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\run_first_grounded_conservative_attempt.ps1
```

For an honest validation-only fallback in an environment without a real player, keep the run explicitly mission-divergent instead of pretending it is the real first grounded attempt:

```powershell
powershell -NoProfile -File .\scripts\run_first_grounded_conservative_attempt.ps1 -AllowMissionOverride -DurationSeconds 20 -HumanJoinGraceSeconds 10 -SkipSteamCmdUpdate -SkipMetamodDownload
```

That fallback is only for validation of the orchestration path. It still must remain non-grounded and excluded from promotion.

Or with the thin wrapper:

```bat
scripts\run_first_grounded_conservative_attempt.bat
```

## Client-Assisted Grounded Conservative Attempt

Use `scripts\run_human_participation_conservative_attempt.ps1` when this machine can launch `hl.exe` and the goal is to turn that local client availability into a real control-then-treatment conservative participation attempt.

- it reuses `discover_hldm_client.ps1`, `join_live_pair_lane.ps1`, and `run_first_grounded_conservative_attempt.ps1`
- it starts the existing first-grounded conservative attempt in the background, waits for the pair root to appear, then launches the local client into the control lane first and the treatment lane second when those ports become active
- on the sequential auto-join path it now keeps the client in control until the control-first switch gate says control is actually safe to leave, then keeps the client in treatment until the treatment-hold gate says grounded patch evidence is actually ready
- it writes `human_participation_conservative_attempt.json` and `human_participation_conservative_attempt.md`
- it records exact join commands, the control-first switch helper command and verdict, the treatment-hold helper command and verdict, whether control/treatment auto-launch was attempted, whether saved lane evidence actually showed human presence, and which grounded criteria were still missing if the run stayed non-grounded
- it must not claim human-rich grounded evidence just because `hl.exe` launched; the report stays tied to the saved lane evidence and certification output

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\run_human_participation_conservative_attempt.ps1
```

## Control-First Switch Gate

Use `scripts\guide_control_to_treatment_switch.ps1` when the operational question is "is control finally safe to leave, or exactly what is still missing?"

- it reads the mission thresholds first, then combines pair artifacts and the guided monitor verdict history to answer whether the operator should stay in control, switch now, keep waiting in treatment, or accept that the pair timed out non-grounded
- it is narrower than `monitor_live_pair_session.ps1`: the broader live monitor answers whether the whole pair is sufficient, while this helper answers whether the control-to-treatment handoff is justified yet
- on a failed pair it makes the blocker explicit, such as "control was still short by 1 snapshot and 20 seconds"

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\guide_control_to_treatment_switch.ps1 -PairRoot <pair-root> -Once
powershell -NoProfile -File .\scripts\guide_control_to_treatment_switch.ps1 -UseLatest
```

## Treatment-Hold Patch Window Gate

Use `scripts\guide_treatment_patch_window.ps1` when control already cleared and the question becomes whether treatment can finally be left without losing grounded patch evidence.

- it reads the mission thresholds, reuses the current switch/status artifacts, and focuses on treatment-side grounded conditions only
- it is narrower than `monitor_live_pair_session.ps1`: the broader monitor answers whether the whole pair is sufficient, while this helper answers whether treatment itself has the required human-present patch evidence and post-patch window yet
- it explicitly reports the remaining treatment-side blocker such as "still short by 2 counted patch-while-human-present events" or "stay for another 20 post-patch seconds"
- it records when a patch was merely applied during the human window from a recommendation that happened before humans joined, so the operator can see why that still does not count as grounded human-present patch evidence

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\guide_treatment_patch_window.ps1 -PairRoot <pair-root> -Once
powershell -NoProfile -File .\scripts\guide_treatment_patch_window.ps1 -UseLatest
```

## Sequential Conservative Phase Flow

Use `scripts\guide_conservative_phase_flow.ps1` when the operator needs one live status view for the whole control-to-treatment sequence.

- it reuses the control-first and treatment-hold helpers instead of inventing a new threshold set
- it reports one current phase, one current verdict, and one next operator action
- `phase-control-stay` means remain in control
- `phase-control-ready-switch-now` means control has cleared and it is safe to switch to treatment
- `phase-treatment-waiting-for-human-signal`, `phase-treatment-waiting-for-patch`, and `phase-treatment-waiting-for-post-patch-window` mean stay in treatment until the named blocker clears
- `phase-grounded-ready-finish-now` means the sequential phase flow is satisfied and the live session can finish honestly

```powershell
powershell -NoProfile -File .\scripts\guide_conservative_phase_flow.ps1 -PairRoot <pair-root> -Once
powershell -NoProfile -File .\scripts\guide_conservative_phase_flow.ps1 -UseLatest
```

## Next Grounded Conservative Cycle

Use `scripts\run_next_grounded_conservative_cycle.ps1` once the first grounded conservative session already exists and the next question is whether the newest live conservative run became the second grounded conservative capture or only moved the planner partway forward.

- it reuses the client-assisted conservative attempt path instead of creating a second live-session runner
- because the client-assisted helper now surfaces the sequential phase-director on the auto-join path, this cycle helper inherits the same control-before-treatment and treatment-before-exit discipline automatically
- it writes `grounded_conservative_cycle_report.json` and `grounded_conservative_cycle_report.md`
- `second-grounded-conservative-capture` means the pair counted toward promotion and moved grounded conservative sessions from `1` to `2`
- `conservative-gap-reduced-but-objective-unchanged` means the pair counted and reduced the gap, but the planner still points at the same next objective after the run
- `conservative-objective-advanced` means the pair counted and the planner moved beyond `collect-more-grounded-conservative-sessions`
- it differs from the first-grounded helper by focusing on milestone advancement after the first capture already exists
- the helper still keeps `responsive` closed unless the existing responsive-gate evaluation actually changes

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\run_next_grounded_conservative_cycle.ps1
```

## Local Client Discovery And Lane Join

Use `scripts\discover_hldm_client.ps1` before a human-rich live pair when you need a direct answer about whether this machine can actually launch `hl.exe` into the lane.

- it checks `-ClientExePath` first, then `HL_CLIENT_EXE`, then standard Steam roots, discoverable Steam library folders, registry Steam hints, and the older locally documented Half-Life install paths
- it writes `local_client_discovery.json` and `local_client_discovery.md`
- `client-not-found` means automatic local launch is unavailable and the operator should rely on the printed loopback/LAN/manual `connect` instructions instead
- preflight now treats missing `hl.exe` as `ready-with-warnings` rather than pretending the environment is fully join-ready

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\discover_hldm_client.ps1
```

Use `scripts\join_live_pair_lane.ps1` to launch or preview the local client for one lane:

- `-Lane Control|Treatment` chooses the lane
- `-PairRoot` or `-UseLatest` makes the helper read the existing pair pack instead of retyping ports
- `-DryRun` shows the exact lane target and client command without launching
- if `hl.exe` is still unavailable, the helper stays honest and reports that prerequisite gap directly

Examples:

```powershell
powershell -NoProfile -File .\scripts\join_live_pair_lane.ps1 -Lane Control -UseLatest -DryRun
powershell -NoProfile -File .\scripts\join_live_pair_lane.ps1 -Lane Treatment -PairRoot D:\DEV\CPP\HL-Bots\lab\logs\eval\fgca40-live\20260420-212515-crossfire-b4-s3-cp27016-tp27017 -DryRun
```

`run_control_treatment_pair.ps1` now writes the pair-aware helper commands into `control_join_instructions.txt`, `treatment_join_instructions.txt`, and `pair_join_instructions.txt`, so the operator can either auto-launch through the helper or keep using the manual `connect` commands.

When the client launches but the pair still records no humans, audit the saved pair before spending another live run:

```powershell
powershell -NoProfile -File .\scripts\audit_client_presence.ps1 -PairRoot .\lab\logs\eval\<pair-root>
```

Read the audit stage-by-stage:

- `client-not-launched`: no saved join attempt exists
- `client-launched-process-only`: the helper recorded a process start but server evidence is still missing
- `client-launched-but-no-server-connect`: `hl.exe` started but lane-local HLDS logs never captured a real client connection
- `client-connected-but-no-lane-attribution`: a connection exists somewhere, but the saved pair cannot attribute it to control or treatment cleanly
- `lane-attribution-present-but-no-human-snapshots`: lane-local connection evidence exists, but telemetry, lane summaries, live monitor, and final pair summary still never count a human player
- `human-snapshots-present-control-only`, `human-snapshots-present-treatment-only`, or `human-snapshots-present-both-lanes`: the signal chain progressed into saved telemetry and summaries

This audit is narrower than certification or the scorecard. It does not decide promotion or behavior quality. It only names where a launched local client stops becoming reflected in saved evidence.

When the audit already narrows the issue to join completion, run the bounded control-lane probe before another full conservative session:

```powershell
powershell -NoProfile -File .\scripts\run_client_join_completion_probe.ps1
```

Read that probe as a smaller reproduction, not as another evidence-collection run:

- it reuses the no-AI control lane, the same local client discovery path, and the same lane-join helper
- it reports the exact completion chain stage-by-stage: `client-discovered`, `launch-command-prepared`, `client-process-launched`, `server-connection-seen`, `entered-the-game-seen`, `first-human-snapshot-seen`, `human-presence-accumulating`, and `control-lane-human-usable`
- `connected-but-not-entered-game` means the server saw the connection, but the saved control-lane evidence still has no trusted in-game join state
- `entered-game-but-no-human-snapshot` means the client joined the game, but the saved control-lane telemetry still never counted a human player
- `human-snapshot-seen-but-presence-does-not-accumulate` means the first counted human snapshot exists, but the saved human-presence window still fails to build into usable evidence
- the system is ready to spend another full strong-signal conservative session only after this probe shows the entered-the-game boundary, at least one counted human snapshot, and human presence starting to accumulate in saved control-lane evidence
- the bounded probe comes first because it isolates the join/signal chain without wasting a treatment lane or another full strong-signal mission on a launch-path defect

When one bounded probe succeeds but reliability is still uncertain, run the repeated join reliability matrix:

```powershell
powershell -NoProfile -File .\scripts\run_client_join_reliability_matrix.ps1 -Attempts 3 -UseLatestMissionContext
```

- it reuses `run_client_join_completion_probe.ps1` in a bounded loop and records one row per attempt
- it writes `client_join_reliability_matrix.json` / `.md` plus `client_join_reliability_certificate.json` / `.md`
- `not-ready-repeat-join-hardening` means repeated bounded probes still failed before saved human presence began accumulating, so another full strong-signal conservative session would be premature
- `partially-reliable-repeat-bounded-probes` means the repaired path is no longer totally blocked, but the repeated suite is still mixed and should stay in bounded-probe mode
- `ready-for-next-strong-signal-attempt` is intentionally strict: the current helper only certifies ready after every repeated bounded attempt reaches entered-the-game, first human snapshot, accumulating saved human presence, and control-lane human-usable without exceeding the matrix time budget
- this matrix is narrower than the broader scorecard or certification flow: it studies join reliability only and does not fabricate grounded promotion evidence by itself

If the repeated suite still fails before join is even attempted, audit the failed probe root directly:

```powershell
powershell -NoProfile -File .\scripts\audit_probe_lane_startup.ps1 -ProbeRoot .\lab\logs\eval\join_reliability_matrices\<matrix-root>\att\<attempt>\<probe-root>
```

- this startup audit is narrower than the later join-completion audit: it only studies lane launch, lane-root materialization, port-ready, and whether the join helper was ever invoked
- `lane root materialized` means the bounded probe really created the lane capture root and lane metadata under the probe output root
- `port ready` means the bounded control lane reached a real listener on the target port before the join helper gate
- `lane-launch-attempted-no-root` means startup never created a lane root; if stderr also saved a missing `Resolve-Path` lane root, that is strong evidence of path-depth startup failure
- `lane-root-created-no-port-ready` means the lane root exists, but the bounded control lane still never became ready on the target port
- `port-ready-no-join-invocation` means the bounded control lane cleared startup readiness, but the join helper still was not invoked
- only return to another full strong-signal conservative attempt after repeated bounded probes reliably clear the startup/materialization gates and any remaining break point is later in the join or telemetry chain

When startup is already healthy but repeated probes still fail before `entered the game` becomes reliable, compare a known successful bounded probe against the failed repeated probes directly:

```powershell
powershell -NoProfile -File .\scripts\audit_entered_game_boundary.ps1 -UseLatest
```

- this entered-the-game audit is narrower than the broader client-presence audit: it compares successful and failed bounded probes around launch, connect, and admission timing only
- it checks launch-command equivalence, working-directory equivalence, lane-ready timing, server-side `connected` / `entered the game` timestamps, and any saved early client-exit evidence
- `connected-but-never-entered-game` means at least one failed repeated probe reaches server connect, but still does not cross into the fully admitted in-game state
- `entered-game-racy` means the same launch path already succeeded once and the lane was ready before launch, so the remaining divergence is timing/admission reliability rather than a static configuration mismatch
- stay in bounded-probe mode until the repeated reliability matrix shows the entered-the-game boundary is stable across the suite, not just on one successful probe

When the repeated probe already reaches `entered the game`, but the first saved human snapshot still appears missing, run the narrower first-human-snapshot boundary audit:

```powershell
powershell -NoProfile -File .\scripts\audit_first_human_snapshot_boundary.ps1 -ProbeRoot .\lab\logs\eval\join_reliability_matrices\<matrix-root>\att\<attempt>\<probe-root>
```

- this boundary audit is narrower than the broader client-presence audit: it compares authoritative HLDS join lines and telemetry history against the secondary lane summary/session artifacts
- `snapshot-written-but-summary-not-updated` means `telemetry_history.ndjson` already contains the first human snapshot, but the saved summary/session layer still failed to reflect it
- `first-human-snapshot-seen` means the saved lane summary now reflects the first counted human snapshot, even if accumulated human presence is still thin
- `human-presence-accumulating` means the later summary layer is no longer the blocker and saved human-presence seconds are actually building

When one or more bounded probes already succeed end to end, but a full strong-signal conservative session still records `control-baseline-no-humans` / `ai-healthy-no-humans`, compare the bounded and full paths directly:

```powershell
powershell -NoProfile -File .\scripts\audit_bounded_vs_full_session_divergence.ps1
```

- this divergence audit is broader than the entered-the-game audit but narrower than a generic pair review: it compares a successful bounded probe root against a failed full-session pair root
- it lines up launch command, working directory, pair/lane roots, control/treatment join attempts, control/treatment phase-gate outputs, and the timestamps for launch, connect, entered-the-game, first human snapshot, and accumulating human presence
- `bounded-success-full-control-never-cleared` means the already-working bounded join path still diverged earlier inside the full control-first workflow, so treatment never got a fair live chance
- `bounded-success-full-treatment-never-joined` means the divergence is no longer in bare launch readiness; the full sequence itself still failed to carry human signal into treatment
- `bounded-success-full-summary-ingestion-missing` means the full session reached the same authoritative join boundary as the bounded probe, but later pair/lane reflection still diverged
- spend another full strong-signal conservative session only after the divergence audit shows the full-session path is aligned with the working bounded path or after one bounded-plus-full validation pair confirms the repair
- use this helper after the startup audit and after the broader join-completion probe when the break point is clearly between authoritative player entry and saved summary reflection

When the join path already survives inside the full workflow but control-side accumulation still stops short of the stronger target, prove the control-only phase before another treatment spend:

```powershell
powershell -NoProfile -File .\scripts\run_control_phase_accumulation_probe.ps1
```

- this helper keeps the human in the no-AI control lane only and reuses the strong-signal mission, local client discovery, join helper, control-first gate, and existing closeout artifacts
- `control-phase-strong-signal-target-met` means the full control phase really did clear the stronger target, so the next full strong-signal conservative control+treatment attempt is justified
- `control-phase-human-usable-but-below-strong-signal-target` means the control lane already became human-usable, but still stayed below the stronger `5` snapshots / `90` seconds bar
- `control-phase-insufficient-human-signal` means the control-only proof still failed earlier and another full control+treatment spend would still be premature
- this helper is narrower than the broader client-presence or bounded-vs-full divergence audits because it assumes admission is already workable and focuses only on proving or disproving full-session control accumulation

When the control-only proof already succeeds but a full strong-signal conservative rerun still fails to turn control-ready into treatment and clean closeout, audit that later handoff chain directly:

```powershell
powershell -NoProfile -File .\scripts\audit_full_session_handoff.ps1
```

- this helper differs from the control-only proof because it starts after control is already safe to leave; it is not asking whether control can accumulate enough signal, only whether the full runner actually observes that readiness, launches treatment, and finishes closeout
- this helper also differs from the bounded join-completion probe because it is not a one-lane launch test; it reads full pair-session artifacts such as `control_to_treatment_switch.json`, `conservative_phase_flow.json`, `treatment_patch_window.json`, `live_monitor_status.json`, `guided_session\mission_execution.json`, `guided_session\session_state.json`, and `guided_session\final_session_docket.json`
- `control-ready-observed-but-treatment-join-not-invoked` means the full sequence left the control phase logically, but no trustworthy treatment join request or launch was saved
- `treatment-phase-started-but-closeout-raced` means treatment-stage waiting began, but final pair artifacts still did not survive clean closeout
- `closeout-raced-before-final-artifacts` means the pair root exists, but `pair_summary.json` or the final docket still disappeared before the session finished honestly
- another full strong-signal conservative attempt is justified after this helper reaches `handoff-chain-complete` or after one narrow repair plus one justified rerun proves treatment-phase start and final artifact production

When the latest repaired full rerun already counts as grounded evidence but still fails to capture treatment-side strong-signal evidence, audit that gap like this before another live spend:

```powershell
powershell -NoProfile -File .\scripts\audit_treatment_strong_signal_gap.ps1 -UseLatest -DryRun
powershell -NoProfile -File .\scripts\audit_treatment_strong_signal_gap.ps1 -PairRoot .\lab\logs\eval\ssca53-live\<pair-pack> -DryRun
```

- this helper is narrower than the broader grounded-evidence matrix because it assumes a valid grounded pair already exists and asks only whether the remaining treatment-side strong-signal gap is real
- it also differs from `reconcile_pair_metrics.ps1`: that helper reconciles a counted pair generally, while this one applies a treatment strong-signal precedence order and says whether wrapper drift is merely narrative or actually substantive
- canonical sources are `pair_summary.json`, treatment `summary.json`, `grounded_evidence_certificate.json`, patch history, patch-apply history, telemetry history, and human-presence timing
- secondary sources are `treatment_patch_window.json`, `conservative_phase_flow.json`, `live_monitor_status.json`, `mission_attainment.json`, `strong_signal_conservative_attempt.json`, and related wrapper summaries
- `strong-signal-gap-real-treatment-still-short` means the next full conservative session must still capture the missing treatment-side event or window
- `patch-event-under-count-in-derived-layer`, `post-patch-window-under-count-in-derived-layer`, and `strong-signal-criteria-met-but-wrapper-stale` are refresh-only branches; dry-run first and execute only the listed safe secondary refresh commands when the helper says promotion state stays unchanged

When a later treatment completion run regresses from a better `5 / 100` window down to a shorter `4 / 80` window, compare the better and regressed pair roots directly before another live spend:

```powershell
powershell -NoProfile -File .\scripts\audit_treatment_dwell_and_patch_consistency.ps1
powershell -NoProfile -File .\scripts\audit_treatment_dwell_and_patch_consistency.ps1 -BetterPairRoot .\lab\logs\eval\ssca53-live\<better-pair> -RegressedPairRoot .\lab\logs\eval\ssca53-live\<regressed-pair>
```

- this helper differs from the earlier treatment strong-signal gap audit because it is not asking whether the latest grounded rerun truly met strong-signal; it is asking why a later run became shorter and whether that regression is real or only secondary artifact drift
- canonical sources remain treatment `summary.json`, `pair_summary.json`, `grounded_evidence_certificate.json`, patch history, patch-apply history, telemetry history, and the saved human-presence timeline
- secondary sources remain `treatment_patch_window.json`, `conservative_phase_flow.json`, `live_monitor_status.json`, `mission_attainment.json`, and wrapper narratives such as `human_participation_conservative_attempt.json` and `strong_signal_conservative_attempt.json`
- `real-treatment-dwell-regression` means the later run really lost treatment time before the next human sample could land, so refresh-only cleanup is not enough and the next step remains treatment-hold hardening
- `derived-layer-patch-undercount-only` means canonical treatment evidence stayed stable and only the secondary layer needs a safe refresh
- use refresh-only cleanup only when the helper says the disagreement is confined to secondary artifacts; otherwise explain the dwell loss first and delay another full strong-signal conservative spend

When that audit already proves the remaining blocker is one missing treatment patch-while-humans-present event, use the dedicated completion helper for the next real conservative spend:

```powershell
powershell -NoProfile -File .\scripts\run_treatment_patch_completion_attempt.ps1
```

- this helper is narrower than the earlier generic strong-signal conservative attempt because it assumes the remaining blocker is already known and centers the report on treatment patch completion
- it still reuses the strong-signal mission, mission-driven runner, local client discovery, join helpers, control-first guidance, treatment-hold guidance, live monitor, certification, mission attainment, outcome dossier, grounded-evidence matrix, responsive gate, and next-live planner
- `third human-present patch captured` means the canonical counted treatment patch-events metric moved from `2 / 3` to `3 / 3` while humans were still present
- a successful result means treatment becomes strong-signal-ready and the first strong-signal conservative evidence pack is finally captured
- an unsuccessful result means either treatment still stayed short of the third patch event or the session lost enough human signal that the target could not be evaluated honestly
- `responsive` still stays closed unless the saved pair really changes the counted strong-signal evidence state

When the latest regressed full rerun looks one human sample short, audit the treatment closeout cutoff directly before another live spend:

```powershell
powershell -NoProfile -File .\scripts\audit_treatment_closeout_cutoff.ps1
powershell -NoProfile -File .\scripts\audit_treatment_closeout_cutoff.ps1 -PairRoot .\lab\logs\eval\ssca53-live\<regressed-pair>
```

- this helper is narrower than `audit_treatment_dwell_and_patch_consistency.ps1`: the dwell audit explains why one treatment run regressed against another, while this one asks whether the later run actually started closeout before the next expected human sample could land
- `next expected human sample` means the next treatment-side human snapshot implied by the saved treatment human-presence cadence, normally the 20-second telemetry interval
- `closeout-started-before-next-expected-human-sample` means treatment was still below target, `safe_to_leave_treatment` was false, and the next expected sample was imminent enough that one bounded hold could plausibly change the dwell result
- `closeout-started-while-safe_to_leave_false` means treatment still was not safe to leave, but the timing is not tight enough to prove a one-sample cutoff
- the closeout guard is intentionally bounded: it can hold the treatment lane open for one short grace window, wait for the next expected sample or lane end, then recompute without loosening any thresholds
- if a guarded rerun fixes treatment dwell but the third human-present patch is still missing, treat that as real progress but still not as a strong-signal capture

If the post-guard full rerun collapses earlier and never produces a valid final pair pack, audit that artifact gap directly before another live spend:

```powershell
powershell -NoProfile -File .\scripts\audit_full_rerun_artifact_gap.ps1
powershell -NoProfile -File .\scripts\audit_full_rerun_artifact_gap.ps1 -PairRoot .\lab\logs\eval\ssca53-live\<failed-rerun-pair>
```

- this helper is narrower than the treatment closeout-cutoff audit: it assumes the validating rerun never even reached a trustworthy final pair pack, so the problem is earlier than treatment-side cutoff analysis
- it maps the exact artifact gap across mission snapshot, mission execution, control-to-treatment switch, phase flow, live monitor, pair summary, grounded certificate, mission attainment, and final session docket
- `process-exit-before-summary-flush` means the pair runner itself died before the raw lane summary or pair summary existed, so downstream closeout helpers could not be trusted to salvage the run
- `pair-summary-missing-but-recoverable` means the lane-level evidence survived and pair-local salvage may still be safe
- use the explicit salvage-vs-rerun decision to choose between existing recovery helpers and another full strong-signal conservative attempt

When the goal is the first client-assisted grounded conservative attempt instead of a one-lane manual join, prefer:

```powershell
powershell -NoProfile -File .\scripts\run_human_participation_conservative_attempt.ps1
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
- `human_presence_timeline.ndjson` or the shorter fallback alias `human_timeline.ndjson` when deep bounded-probe roots would otherwise exceed the classic Windows path limit

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
