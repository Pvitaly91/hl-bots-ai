# hl-bots-ai

PROMPT_ID_BEGIN
HLDM-JKBOTTI-AI-STAND-20260415-08
PROMPT_ID_END

`hl-bots-ai` is a Windows-first Half-Life Deathmatch bot lab built on top of the upstream [Bots-United/jk_botti](https://github.com/Bots-United/jk_botti) codebase. The repository keeps the original jk_botti source layout in the repo root, adds a Visual Studio 2022 Win32 build, and layers in a slow AI balance director that adjusts only high-level bot tuning through a file bridge.

The lab is designed to keep working offline. If no `OPENAI_API_KEY` is present, the Python sidecar uses a deterministic rules engine. If the sidecar is absent or errors, the server and bot plugin still run.

## What This Repo Contains

- Upstream `jk_botti` source imported into the repository root with upstream attribution preserved.
- `hl-bots-ai.sln` and `jk_botti_mm.vcxproj` for Visual Studio 2022 `Win32|Debug` and `Win32|Release`.
- `ai_balance.cpp` and related hooks in the plugin for telemetry export and bounded patch application.
- `ai_director/` Python sidecar for offline fallback rules and optional OpenAI Responses API usage.
- `scripts/` PowerShell automation for setup, build, launch, and smoke testing on Windows.
- `docs/test-stand.md` with local HLDS lab details.
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

Examples:

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
- Bootstrap attach log: `valve/addons/jk_botti/runtime/bootstrap.log`
- Generated bot test config: `lab/hlds/valve/addons/jk_botti/jk_botti_<map>.cfg`
- Bot test config template: `addons/jk_botti/test_bots.cfg`
- Generated no-AI baseline config: `lab/hlds/valve/addons/jk_botti/jk_botti_<map>.cfg`
- AI director logs: `lab/logs/ai_director.stdout.log` and `lab/logs/ai_director.stderr.log`
- HLDS logs: `lab/logs/hlds.stdout.log` and `lab/logs/hlds.stderr.log`
- Server install root by default: `lab/hlds`

The generated map-specific config pins `botskill`, `min_bots`, `max_bots`, and a matching set of `addbot` lines so the requested bot pool comes up predictably and can be regenerated safely on each launcher run.

## Scripts

- `scripts/build_vs2022.ps1`: builds the VS2022 solution and verifies the staged DLL exists.
- `scripts/setup_test_stand.ps1`: installs or updates SteamCMD/HLDS, downloads Metamod-P, writes `plugins.ini`, patches `liblist.gam`, and copies jk_botti lab files.
- `scripts/run_ai_director.ps1`: runs the Python sidecar once or as a background process.
- `scripts/run_server.ps1`: launches HLDS for the `valve` mod on a local LAN-safe configuration.
- `scripts/run_lab.ps1`: convenience entry point that sets up the lab, launches the sidecar, and launches HLDS.
- `scripts/run_test_stand_with_bots.ps1`: one-command test launcher that builds, prepares the lab, generates the map-specific bot config, starts the sidecar, and starts HLDS.
- `scripts/run_test_stand_with_bots.bat`: `cmd.exe` wrapper for the one-command local bot test flow.
- `scripts/run_standard_bots_crossfire.ps1`: baseline launcher that builds, prepares the lab, writes a deterministic no-AI map config with `jk_ai_balance_enabled 0`, and starts HLDS without the Python sidecar.
- `scripts/run_standard_bots_crossfire.bat`: `cmd.exe` wrapper for the baseline no-AI crossfire flow.
- `scripts/smoke_test.ps1`: classifies attach/load state for AI and no-AI runs and validates telemetry, patch output, and patch application when AI mode is expected.
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
- Interpret `scripts\smoke_test.ps1` by mode. `-Mode NoAI` should return `no-ai-path-active-by-design` for the standard baseline; `-Mode AI` should advance to `patch-applied`. Other statuses distinguish `hlds-did-not-start`, `metamod-did-not-load`, `plugin-dll-file-missing`, `plugin-dll-load-failed`, `plugin-loaded-but-meta-query-failed`, `plugin-passed-meta-query-but-did-not-attach`, `plugin-attached-but-no-telemetry`, and `telemetry-emitted-but-no-patch-path-yet`.

## Known Limitations

- Full end-to-end smoke coverage still depends on external HLDS and Metamod downloads.
- The OpenAI path is optional and deliberately not used from per-frame bot code.
- The AI layer only adjusts coarse balance knobs. It does not rewrite waypointing, aim code, or hidden-information access.
- The current telemetry model is tuned for HLDM free-for-all, not team objective mods.
- Runtime paths assume the standard `valve` HLDM layout for the Windows lab scripts.

## Upstream Attribution

This repository incorporates the upstream jk_botti project from [Bots-United/jk_botti](https://github.com/Bots-United/jk_botti). Original source files, licenses, and addon content were preserved and extended rather than relicensed or rewritten wholesale.
