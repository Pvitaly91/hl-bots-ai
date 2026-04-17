# hl-bots-ai

PROMPT_ID_BEGIN
HLDM-JKBOTTI-AI-STAND-20260415-20
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
- each paired run writes `pair_summary.json`, `pair_summary.md`, `comparison.json`, `comparison.md`, `control_join_instructions.txt`, `treatment_join_instructions.txt`, and the nested lane/session-pack folders.

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

For the first real human pair session, use this operator flow:

1. `powershell -NoProfile -File .\scripts\preflight_real_pair_session.ps1`
2. `powershell -NoProfile -File .\scripts\run_control_treatment_pair.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -ControlPort 27016 -TreatmentPort 27017 -DurationSeconds 80 -WaitForHumanJoin -HumanJoinGraceSeconds 120 -TreatmentProfile conservative -SkipSteamCmdUpdate -SkipMetamodDownload`
3. join the printed control lane first
4. join the printed treatment lane second
5. `powershell -NoProfile -File .\scripts\review_latest_pair_run.ps1`
6. `powershell -NoProfile -File .\scripts\score_latest_pair_session.ps1`
7. use the scorecard recommendation to choose the next live action

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

Interpret the scorecard treatment assessment like this:

- `too quiet`: humans were present long enough to compare lanes, but conservative stayed quieter than control without grounded human-present patch evidence.
- `appropriately conservative`: conservative produced grounded human-present patch evidence without looking oscillatory or overactive.
- `inconclusive`: human presence, patch timing, or post-patch observation windows were still too weak to justify a profile decision.
- `too reactive`: the treatment lane looked oscillatory or violated a guardrail, so artifacts need manual review before another live profile choice.

Use the scorecard recommendation conservatively:

- `keep-conservative-and-collect-more`: conservative already looks healthy enough to remain the live default.
- `treatment-evidence-promising-repeat-conservative`: there is promising live signal, but repeat conservative before considering a profile change.
- `weak-signal-repeat-session`: humans joined, but the post-patch evidence stayed weak; repeat conservative first.
- `conservative-looks-too-quiet-try-responsive-next`: only justified when humans were present long enough to compare lanes and conservative still stayed too quiet.
- `insufficient-data-repeat-session`: reject the session for tuning and collect another live pair first.
- `review-artifacts-manually`: inspect `comparison.md`, `scorecard.md`, and the treatment lane summary before choosing the next action.

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

Use the sweep results to pick the next live treatment profile, then pass the same name back into `scripts\run_balance_eval.ps1`, `scripts\run_mixed_balance_eval.ps1`, or `scripts\run_control_treatment_pair.ps1` with `-TuningProfile <name>`. Start live pair work with `conservative`. Only move to `responsive` after a conservative pair pack says the treatment lane stayed too quiet relative to control or never produced a grounded human-present patch window.

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
- Pair summaries: `lab/logs/eval/pairs/<timestamp>-.../pair_summary.json` and `pair_summary.md`
- Pair comparisons: `lab/logs/eval/pairs/<timestamp>-.../comparison.json` and `comparison.md`
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
- `scripts/preflight_real_pair_session.ps1`: operator-facing preflight that verifies build output, required scripts, known paths, control/treatment ports, the conservative treatment profile, and optional local client-helper readiness before a real human pair session.
- `scripts/preflight_real_pair_session.bat`: `cmd.exe` wrapper for the real pair-session preflight helper.
- `scripts/review_latest_pair_run.ps1`: finds the newest pair pack, prints the key artifact paths, summarizes the control/treatment verdicts, and points to the next artifact worth reading.
- `scripts/score_latest_pair_session.ps1`: writes `scorecard.json` and `scorecard.md` into a pair pack, classifies the treatment lane as too quiet / appropriately conservative / inconclusive / too reactive, and emits an explicit next-action recommendation.
- `scripts/score_latest_pair_session.bat`: `cmd.exe` wrapper for the scorecard helper.
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
