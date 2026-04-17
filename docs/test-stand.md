# HLDM Test Stand

PROMPT_ID_BEGIN
HLDM-JKBOTTI-AI-STAND-20260415-12
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
powershell -NoProfile -File .\scripts\run_balance_eval.ps1 -Mode AI -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -DurationSeconds 80 -SkipSteamCmdUpdate -SkipMetamodDownload
```

Run an AI treatment lane intended for human participation:

```powershell
powershell -NoProfile -File .\scripts\run_balance_eval.ps1 -Mode AI -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -DurationSeconds 80 -WaitForHumanJoin -HumanJoinGraceSeconds 120 -MinHumanSnapshots 2 -MinHumanPresenceSeconds 40 -LaneLabel mixed-session-treatment -SkipSteamCmdUpdate -SkipMetamodDownload
```

Use the dedicated mixed-session helper when the goal is to bring a human into the lane quickly:

```powershell
powershell -NoProfile -File .\scripts\run_mixed_balance_eval.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -Port 27017 -DurationSeconds 80 -WaitForHumanJoin -HumanJoinGraceSeconds 120 -MinHumanSnapshots 2 -MinHumanPresenceSeconds 40 -LaneLabel mixed-session-treatment -SkipSteamCmdUpdate -SkipMetamodDownload
```

The mixed-session helper prints the join target before launch and saves the same join instructions into the lane folder as `join_instructions.txt`.

Summarize a control-vs-treatment pair:

```powershell
powershell -NoProfile -File .\scripts\summarize_balance_eval.ps1 `
  -LaneRoot .\lab\logs\eval\<control-lane> `
  -CompareLaneRoot .\lab\logs\eval\<treatment-lane> `
  -OutputJson .\lab\logs\eval\comparison.json `
  -OutputMarkdown .\lab\logs\eval\comparison.md
```

Run the replay/scenario tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\common.ps1; `$pythonExe = Get-PythonPath -PreferredPath ''; & `$pythonExe -m unittest ai_director.tests.test_decision ai_director.tests.test_replay_scenarios"
```

Use the replay scenarios first when tuning thresholds or hysteresis. They are deterministic, do not require a live server, and cover one-human dominance, one-human struggles, sparse joins, oscillation-prone alternation, spike-and-stabilize patterns, and close games where AI should remain conservative.

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

If `OPENAI_API_KEY` is absent, the launcher stays in offline fallback mode and the Python sidecar uses the deterministic rules engine. To switch to OpenAI mode later, set `OPENAI_API_KEY` in `.env` or the environment and rerun the same launcher.

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
