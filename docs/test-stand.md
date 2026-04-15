# HLDM Test Stand

This document describes the Windows-first local HLDM lab added on top of jk_botti.

## Default Lab Layout

By default the scripts use `.\lab` under the repository root:

- `lab\tools\steamcmd\`: SteamCMD install if one is not already provided.
- `lab\hlds\`: HLDS dedicated server root installed through SteamCMD app `90` with `mod valve`.
- `lab\logs\`: sidecar and HLDS stdout/stderr capture.
- `lab\hlds\valve\addons\jk_botti\runtime\ai_balance\`: telemetry and patch bridge folder used by the plugin and sidecar.

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

Smoke test the running lab:

```powershell
powershell -NoProfile -File .\scripts\smoke_test.ps1 -TimeoutSeconds 120
```

## Sidecar Configuration

The sidecar can be configured through environment variables or `.env` files loaded from either:

- `.\ai_director\.env`
- `.\.env`

Supported values:

- `OPENAI_API_KEY`: optional; if omitted, fallback rules are used.
- `OPENAI_MODEL`: optional; defaults to `gpt-4o-mini`.
- `AI_DIRECTOR_POLL_INTERVAL`: optional; defaults to `5`.
- `AI_DIRECTOR_LOG_LEVEL`: optional; defaults to `INFO`.

## Smoke Test Expectations

`scripts/smoke_test.ps1` waits for all of the following:

- staged `jk_botti_mm.dll` exists,
- `plugins.ini` references `jk_botti_mm.dll`,
- telemetry JSON appears in the runtime directory,
- patch JSON appears in the runtime directory,
- HLDS log contains Metamod plugin attach output,
- HLDS log contains an `[ai_balance] applied patch=` line.

If HLDS or Metamod was not installed yet, or the server was not started, the smoke test will time out rather than trying to repair the environment.

## Operational Notes

- The scripts are written for Win32 HLDS and should not be switched to x64.
- Runtime JSON files are rewritten atomically to reduce partial read/write races.
- The plugin applies only bounded patch values and ignores repeated or stale patches.
- Generated downloads, logs, and binaries live under ignored paths and should not be committed.
