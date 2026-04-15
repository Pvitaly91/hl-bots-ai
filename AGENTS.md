# AGENTS.md

## Build Targets

- Primary Windows target: `hl-bots-ai.sln` with `jk_botti_mm.vcxproj`
- Supported VS configs: `Debug|Win32` and `Release|Win32`
- Staged DLL output: `build/bin/<Configuration>/Win32/addons/jk_botti/dlls/jk_botti_mm.dll`
- Cross-platform upstream `Makefile` remains in place and should not be broken without a clear reason

## Repository Rules

- This repository is Windows-first for the local lab, but HLDS remains a 32-bit-oriented target. Keep Visual Studio builds on `Win32/x86`, not `x64`.
- Preserve upstream jk_botti attribution, addon files, and license materials.
- Do not commit lab downloads, SteamCMD payloads, HLDS installs, Metamod archives, generated waypoints, logs, compiled binaries, secrets, API keys, or local credential files.
- Prefer small, reviewable changes that preserve the upstream layout.

## AI Balance Constraints

- The AI layer may only influence slow, high-level balance knobs.
- Never call OpenAI from a bot per-frame or per-think loop.
- Never give bots hidden information, impossible reaction times, wallhack behavior, or cheating aim.
- Balance changes must stay bounded, reversible, and cooldown-gated.
- The system must fail open: if the sidecar is absent or errors, the server and bots must still run.
