# HLDM Test Stand

PROMPT_ID_BEGIN
HLDM-JKBOTTI-AI-STAND-20260415-24
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
- it keeps the control lane sidecar-free while still honoring human-join-aware wait thresholds

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

For the next real human-vs-bot session, use this sequence:

1. Run `scripts\preflight_real_pair_session.ps1` and stop only if it reports `blocked`.
2. Start `scripts\run_control_treatment_pair.ps1` with the default `conservative` treatment profile.
3. Join the control lane on the printed `ControlPort` target first and play long enough to keep a human present for roughly the configured `-MinHumanPresenceSeconds`.
4. Let the pair runner switch to the treatment lane, then join the printed `TreatmentPort` target second and repeat.
5. Run `scripts\review_latest_pair_run.ps1`.
6. Run `scripts\run_shadow_profile_review.ps1 -UseLatest -Profiles conservative default responsive`.
7. Run `scripts\score_latest_pair_session.ps1`.
8. Run `scripts\register_pair_session_result.ps1`.
9. Run `scripts\summarize_pair_session_registry.ps1`.
10. Run `scripts\evaluate_responsive_trial_gate.ps1`.
11. Use the scorecard, shadow recommendation, registry recommendation, and responsive-trial gate together before the next live action.

The saved join helpers make the roles explicit:

- `control_join_instructions.txt`: no-AI baseline, `jk_ai_balance_enabled 0`, no sidecar
- `treatment_join_instructions.txt`: AI treatment lane, chosen tuning profile, expected join target
- `pair_join_instructions.txt`: the whole paired sequence, useful-session expectations, and pair-pack root

Why `conservative` is the default next live treatment profile:

- it demands more human signal before claiming usefulness
- it reacts more slowly near the boundary, which reduces the chance of overreading one noisy session
- it is the safest way to learn whether live treatment is too quiet before escalating to `responsive`

Try `responsive` only after the responsive-trial gate opens on repeated real grounded conservative-too-quiet evidence. One noisy scorecard or synthetic fixture alone is not enough.

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
- registry entries record the pair ID/root, sortable run identity, map, bot count, bot skill, control/treatment lane labels, treatment profile, pair classification, lane verdicts, evidence quality, whether treatment patched while humans were present, whether a meaningful post-patch window existed, scorecard recommendation, treatment-behavior assessment, optional shadow-review decision fields when present, whether the session is tuning-usable, optional notes path, and embedded prompt/commit metadata when available.
- notes remain optional. Pass `-NotesPath` or drop a notes file into the pair root if an operator wants to keep lightweight context with the objective evidence.
- `scripts\summarize_pair_session_registry.ps1` writes `registry_summary.json`, `registry_summary.md`, `profile_recommendation.json`, and `profile_recommendation.md` under `lab\logs\eval\registry\`.
- `scripts\summarize_pair_session_registry.ps1 -EvaluateResponsiveTrialGate` can refresh the latest responsive-trial gate in the same pass.
- the summary answers how many usable sessions exist for each profile, how often treatment patched while humans were present, whether the dataset is still dominated by insufficient-data or weak-signal runs, how often shadow review suggested keep conservative, insufficient-data-no-promotion, responsive-candidate, or responsive-too-reactive, and whether responsive is justified or should be rejected or reverted.
- profile promotion stays intentionally conservative: no-human and weak-signal sessions do not justify responsive, one noisy session does not justify a profile change, and conservative remains the default until repeated grounded evidence says otherwise.

Interpret the aggregate recommendation like this:

- `keep-conservative`: the current live default is still behaving safely.
- `collect-more-conservative-evidence`: there is some usable signal, but not enough repeated grounded evidence yet to promote or reject conservative.
- `conservative-validated-try-responsive`: only justified after repeated grounded conservative sessions show that conservative is consistently too quiet under real human presence.
- `responsive-too-reactive-revert-to-conservative`: grounded responsive evidence already shows overreaction and the next live profile should move back to conservative.
- `insufficient-data-repeat-session`: the registry is still dominated by plumbing-only or no-human evidence.
- `weak-signal-repeat-session`: humans joined, but the accumulated post-patch evidence is still too weak for a profile change.
- `manual-review-needed`: the ledger has conflicting grounded evidence or a guardrail concern that needs a manual read before the next live action.

## Responsive Trial Gate

Use `scripts\evaluate_responsive_trial_gate.ps1` when you need an explicit go/no-go verdict for the first real live `responsive` treatment session.

- it writes `responsive_trial_gate.json`, `responsive_trial_gate.md`, `responsive_trial_plan.json`, and `responsive_trial_plan.md` under `lab\logs\eval\registry\`
- it reads the registry first and reuses the latest `registry_summary.json` / `profile_recommendation.json` when they already exist
- the thresholds live in `ai_director\testdata\responsive_trial_gate.json` so the promotion rule is explicit and inspectable
- synthetic-only evidence, insufficient-data sessions, weak-signal sessions, and one-off noisy sessions must never unlock the live responsive trial
- repeated real grounded conservative-too-quiet evidence across distinct pair runs may unlock one bounded responsive trial
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

The demo copies the synthetic pair packs into a scratch evaluation root, runs shadow review, scores every pair, registers them into a synthetic registry, and emits a compact branch summary. Treat that output as workflow validation only, never as a substitute for real live human evidence.

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
