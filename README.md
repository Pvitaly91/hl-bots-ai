# hl-bots-ai

PROMPT_ID_BEGIN
HLDM-JKBOTTI-AI-STAND-20260415-80
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
- `scripts/build_latest_session_outcome_dossier.ps1` and `scripts/build_latest_session_outcome_dossier.bat` for the one-shot post-session outcome dossier that consolidates scorecard, shadow review, grounded certification, latest-session delta, responsive gate, and next-live planning into one operator-facing artifact.
- `scripts/plan_next_live_session.ps1` and `scripts/plan_next_live_session.bat` for explicit promotion-gap accounting that says what certified grounded evidence is still missing before responsive can open and what the next conservative live session should try to prove.
- `scripts/prepare_next_live_session_mission.ps1` and `scripts/prepare_next_live_session_mission.bat` for the pre-run operator mission brief that turns the current planner, gate, and latest outcome context into one exact next-session target artifact before launch.
- `scripts/run_current_live_mission.ps1` and `scripts/run_current_live_mission.bat` for mission-driven launch, drift detection, dry-run inspection, and explicit mission-execution recording before the guided workflow starts.
- `scripts/assess_latest_session_recovery.ps1` and `scripts/assess_latest_session_recovery.bat` for interruption classification, artifact-completeness checks, and conservative recovery recommendations after an incomplete or suspicious session.
- `scripts/finalize_interrupted_session.ps1` and `scripts/finalize_interrupted_session.bat` for conservative salvage of recoverable interrupted sessions when the saved pair already contains enough evidence and only the closeout stack needs to be finished honestly.
- `scripts/continue_current_live_mission.ps1` and `scripts/continue_current_live_mission.bat` for the top-level continuation decision that chooses no-action, review-only, salvage, rerun, or manual review from the latest session state plus the current mission context.
- `scripts/inject_pair_session_failure.ps1` and `scripts/inject_pair_session_failure.bat` for rehearsal-safe staging of controlled interrupted-session branches such as before-sufficiency, during-post-pipeline, or missing-mission-snapshot without touching a real live pair by default.
- `scripts/run_mission_continuation_rehearsal.ps1` and `scripts/run_mission_continuation_rehearsal.bat` for the end-to-end failure-injection rehearsal that starts from the mission-driven launcher, injects a controlled branch, runs recovery assessment plus the continuation controller, and writes a suite report.
- `scripts/run_recovery_branch_matrix.ps1` and `scripts/run_recovery_branch_matrix.bat` for the consolidated recovery branch suite, branch matrix, and operator-readiness certificate that summarize whether the full continuation policy is ready for the first real human-rich conservative session.
- `scripts/run_first_grounded_conservative_attempt.ps1` and `scripts/run_first_grounded_conservative_attempt.bat` for the milestone-oriented conservative live attempt wrapper that runs the current mission, reuses continuation if needed, and writes one concise answer about whether the first grounded conservative evidence pack was actually captured.
- `scripts/run_human_participation_conservative_attempt.ps1` and `scripts/run_human_participation_conservative_attempt.bat` for the client-assisted conservative attempt wrapper that discovers `hl.exe`, drives sequential control-then-treatment joins when possible, and writes one human-participation audit report on top of the existing first-grounded attempt flow.
- `scripts/guide_control_to_treatment_switch.ps1` and `scripts/guide_control_to_treatment_switch.bat` for control-first live guidance that reports the exact remaining control-side deficit and only recommends switching once the control lane has actually cleared the mission minimums.
- `scripts/guide_treatment_patch_window.ps1` and `scripts/guide_treatment_patch_window.bat` for treatment-hold live guidance that reports the exact remaining treatment-side grounded patch deficit and only recommends leaving treatment once human-present patch evidence and the post-patch window are both real.
- `scripts/guide_conservative_phase_flow.ps1` and `scripts/guide_conservative_phase_flow.bat` for the single sequential phase-director that merges the control-first and treatment-hold gates into one authoritative current phase, next operator action, and pair-local phase-flow artifact.
- `scripts/run_next_grounded_conservative_cycle.ps1` and `scripts/run_next_grounded_conservative_cycle.bat` for the next milestone wrapper that reuses the client-assisted conservative path and writes one explicit answer about whether the latest live cycle became the second grounded conservative capture, only reduced the gap, or advanced the next objective.
- `scripts/review_counted_pair_evidence.ps1` and `scripts/review_counted_pair_evidence.bat` for counted-pair reconciliation when authoritative evidence and inherited narrative outputs disagree about whether a historically counted pair should still drive promotion math.
- `scripts/reconcile_pair_metrics.ps1` and `scripts/reconcile_pair_metrics.bat` for canonical metric reconciliation and safe derived-artifact refresh when a counted pair still counts but secondary treatment-side or monitor-derived metrics disagree with the authoritative pair and lane evidence.
- `scripts/refresh_pair_wrapper_narratives.ps1` and `scripts/refresh_pair_wrapper_narratives.bat` for the final wrapper cleanup pass that regenerates stale secondary narratives from canonical pair evidence and writes a separate counted-pair clearance decision without changing registry or promotion state by itself.
- `scripts/recompute_after_pair_clearance.ps1` and `scripts/recompute_after_pair_clearance.bat` for the clearance-aware downstream recompute that builds an additive overlay registry view, reruns summary/gate/planner artifacts against it, and shows whether the cleared pair actually changes the current responsive gate or next-live objective.
- `scripts/review_grounded_evidence_matrix.ps1` and `scripts/review_grounded_evidence_matrix.bat` for the global grounded-evidence matrix and promotion-state review that explain why the current gate/objective remain what they are after pair-level cleanup is finished.
- `scripts/prepare_strong_signal_conservative_mission.ps1` and `scripts/prepare_strong_signal_conservative_mission.bat` for the specialized conservative mission brief that raises the evidence targets above the grounded minimum when the counted grounded evidence is mixed and the next run needs to be more discriminating than another generic grounded session.
- `scripts/run_strong_signal_conservative_attempt.ps1` and `scripts/run_strong_signal_conservative_attempt.bat` for the strong-signal conservative live attempt wrapper that consumes the specialized strong-signal mission, reuses the client-assisted conservative path, and writes one explicit answer about whether the run became the first counted grounded strong-signal conservative session or left the evidence state mixed.
- `scripts/audit_client_presence.ps1` and `scripts/audit_client_presence.bat` for stage-by-stage diagnosis of local-client participation, including launch, server connection, lane attribution, human snapshot accumulation, and final pair-summary reflection.
- `scripts/run_client_join_completion_probe.ps1` and `scripts/run_client_join_completion_probe.bat` for the bounded control-lane probe that proves or disproves the missing transition from launched client to entered-the-game, first counted human snapshot, and accumulating saved human presence before another full strong-signal conservative run is spent.
- `scripts/run_client_join_reliability_matrix.ps1` and `scripts/run_client_join_reliability_matrix.bat` for repeated bounded control-lane probes, per-attempt join-stage classification, and a conservative readiness certificate that says whether the repaired local client path is still not ready, only partially reliable, or ready for the next full strong-signal conservative attempt.
- `scripts/audit_probe_lane_startup.ps1` and `scripts/audit_probe_lane_startup.bat` for the narrower startup/materialization audit that explains whether a failed bounded probe died before lane-root creation, before port-ready, or before join invocation.
- `scripts/audit_first_human_snapshot_boundary.ps1` and `scripts/audit_first_human_snapshot_boundary.bat` for the later ingestion-boundary audit that compares authoritative server and telemetry evidence against saved lane summary artifacts when a player already entered the game but the first counted human snapshot still appears missing.
- `scripts/audit_entered_game_boundary.ps1` and `scripts/audit_entered_game_boundary.bat` for the comparative entered-the-game audit that lines up one successful bounded probe against failed repeated probes to decide whether the current divergence is a static launch mismatch, an admission race, or an early client-exit problem.
- `scripts/audit_bounded_vs_full_session_divergence.ps1` and `scripts/audit_bounded_vs_full_session_divergence.bat` for the later workflow audit that compares a successful bounded probe against a failed full strong-signal session when the join path works in isolation but the full session still records `no humans`.
- `scripts/run_control_phase_accumulation_probe.ps1` and `scripts/run_control_phase_accumulation_probe.bat` for the control-only strong-signal proof that keeps the human in the no-AI control lane until the stronger control target is either met or still proven short before another full control+treatment session is spent.
- `scripts/audit_full_session_handoff.ps1` and `scripts/audit_full_session_handoff.bat` for the later full-session audit that reads the control-ready, treatment-join, treatment-phase, and closeout chain when a full conservative run already proved control readiness but still failed to finish treatment or final artifacts cleanly.
- `scripts/audit_treatment_strong_signal_gap.ps1` and `scripts/audit_treatment_strong_signal_gap.bat` for the later treatment-side audit that distinguishes a real strong-signal evidence shortfall from stale secondary wrapper drift after a valid grounded full rerun already exists.
- `scripts/audit_treatment_dwell_and_patch_consistency.ps1` and `scripts/audit_treatment_dwell_and_patch_consistency.bat` for the narrower comparison between the latest better treatment run and the latest regressed one, with explicit separation between real treatment dwell loss and secondary patch-count drift.
- `scripts/audit_treatment_closeout_cutoff.ps1` and `scripts/audit_treatment_closeout_cutoff.bat` for the narrower cutoff audit that asks whether a regressed treatment run ended just before the next expected human sample while treatment was still unsafe to leave.
- `scripts/audit_full_rerun_artifact_gap.ps1` and `scripts/audit_full_rerun_artifact_gap.bat` for the next failure-stage audit when a post-fix full rerun still does not produce `pair_summary.json`, the grounded certificate, or mission attainment.
- `scripts/run_treatment_patch_completion_attempt.ps1` and `scripts/run_treatment_patch_completion_attempt.bat` for the next narrow live milestone after that audit, where the explicit goal is to capture the missing third treatment patch-while-humans-present event and determine whether the first strong-signal conservative evidence pack was finally produced.
- `scripts/discover_hldm_client.ps1` and `scripts/discover_hldm_client.bat` for honest local `hl.exe` discovery across explicit paths, environment variables, Steam roots, discoverable Steam library folders, registry hints, and legacy local installs.
- `scripts/join_live_pair_lane.ps1` and `scripts/join_live_pair_lane.bat` for pair-aware or port-aware local client launch into the control or treatment lane with dry-run support.
- `scripts/launch_public_hldm_client.ps1` and `scripts/launch_public_hldm_client.bat` for the public-mode local admission attempt that prefers the Steam-native launch path for `sv_lan 0`, records the exact command, PID, working directory, and log paths, and only calls the attempt admitted if the server actually sees a real human connect.
- `scripts/diagnose_public_client_admission.ps1` and `scripts/diagnose_public_client_admission.bat` for the narrow public admission diagnosis that separates Steam-launch failure, client-start-without-admission, pre-connect Steam failure, server-connect-without-entered-game, and real admitted-human outcomes.
- `scripts/compare_public_admission_paths.ps1` and `scripts/compare_public_admission_paths.bat` for the side-by-side comparison of Steam app launch, Steam URI, and direct `hl.exe` public admission paths against one live public server.
- `scripts/run_public_steam_admission_drill.ps1` and `scripts/run_public_steam_admission_drill.bat` for the consolidated prompt-74 Steam/public admission drill that reuses the Steam environment audit and path comparison, then classifies the remaining machine-local blocker.
- `scripts/preflight_public_steam_session.ps1` and `scripts/preflight_public_steam_session.bat` for prompt-75 Steam session readiness checks before spending public admission attempts.
- `scripts/test_public_hldm_launch_variants.ps1` and `scripts/test_public_hldm_launch_variants.bat` for bounded concrete public client launch-variant tests, including Steam app launch, Steam connect URI, Steam run URI, and direct `hl.exe`.
- `scripts/print_public_external_validation_plan.ps1` and `scripts/print_public_external_validation_plan.bat` for an operator-facing external real-client validation plan when local Steam admission remains blocked.
- `scripts/preflight_public_external_access.ps1` and `scripts/preflight_public_external_access.bat` for local public-server reachability checks before involving an external tester.
- `scripts/preflight_public_network_exposure.ps1` and `scripts/preflight_public_network_exposure.bat` for local UDP, firewall, LAN-address, and public status readiness checks before external tester handoff.
- `scripts/configure_public_hlds_firewall.ps1` and `scripts/configure_public_hlds_firewall.bat` for dry-run-first Windows Firewall allow-rule planning, with rule creation only when `-Apply` is explicitly supplied.
- `scripts/prepare_external_tester_package.ps1` and `scripts/prepare_external_tester_package.bat` for a complete external tester handoff package with join command, tester steps, operator watch list, and expected bot behavior.
- `scripts/run_public_external_human_trigger_validation.ps1` and `scripts/run_public_external_human_trigger_validation.bat` for the external real-client human-trigger watcher that starts or attaches to public mode, writes join instructions, and reports whether bots disconnect and repopulate from authoritative status.
- `scripts/audit_steam_public_admission.ps1` and `scripts/audit_steam_public_admission.bat` for the Steam-backed admission-stage audit that narrows failures to steam path resolution, launch, client materialization, CM admission, server connect, or entered-the-game.
- `scripts/validate_public_human_trigger.ps1` and `scripts/validate_public_human_trigger.bat` for the product-minimum public-mode validation pass that starts or attaches to the public `crossfire` server, observes the authoritative public policy state transitions, and records whether a local human actually triggered bot removal and later repopulation.
- `scripts/evaluate_latest_session_mission.ps1` and `scripts/evaluate_latest_session_mission.bat` for the post-run mission-attainment closeout that compares the saved mission brief against the actual captured evidence and says whether the session achieved its stated purpose.
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

The product-minimum public crossfire launcher is:

```bat
scripts\run_public_crossfire_server.bat
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
scripts\run_public_crossfire_server.bat -Map crossfire -BotCountWhenEmpty 4 -BotSkillWhenEmpty 3 -Port 27015 -SkipSteamCmdUpdate -SkipMetamodDownload
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

## Public Crossfire Server Mode

Use the public-mode runner when the goal is a usable HLDM `crossfire` server, not another control/treatment lab session:

```bat
scripts\run_public_crossfire_server.bat -Map crossfire -BotCountWhenEmpty 4 -BotSkillWhenEmpty 3 -Port 27015 -SkipSteamCmdUpdate -SkipMetamodDownload
```

Public mode is intentionally simple:

- default map is `crossfire`
- advanced AI balance is disabled by default
- control/treatment, registry, strong-signal, and responsive-gate workflows stay out of the runtime path
- the server uses one grounded human-count source: GoldSrc `status` over RCON

The public bot policy is explicit:

- if human player count is `0`, public mode sets `jk_botti min_bots` and `max_bots` to the configured empty-server target
- if human player count is greater than `0`, public mode sets the target to `0`, issues `jk_botti kickall`, and keeps bots out while humans remain
- if human player count returns to `0`, public mode waits for the bounded repopulate delay and then restores the configured target

Public mode writes operator-facing status artifacts under `lab\logs\public_server\...`:

- `public_server_status.json`
- `public_server_status.md`

These status files report the current map, port, join targets, human count, bot count, current commanded bot target, policy state, and whether advanced AI balance is enabled.

Launch one explicit local public admission attempt like this:

```bat
scripts\launch_public_hldm_client.bat -ServerAddress 127.0.0.1 -ServerPort 27015 -PublicServerOutputRoot D:\DEV\CPP\HL-Bots\lab\logs\public_server\<run-root> -UseSteamLaunchPath
```

The helper prefers the Steam-native public path when available, keeps the direct `hl.exe` path available for comparison, and writes:

- `public_client_admission_attempt.json`
- `public_client_admission_attempt.md`

These attempt artifacts record the exact launch command, working directory, launcher PID, new `hl.exe` PID set, `qconsole.log` path, Steam connection-log path, server-log path, and whether authoritative server admission was actually observed.

Diagnose one failed public admission attempt like this:

```bat
scripts\diagnose_public_client_admission.bat -AttemptJsonPath D:\DEV\CPP\HL-Bots\lab\logs\public_server\client_admissions\<attempt-root>\public_client_admission_attempt.json
```

The diagnosis helper writes:

- `public_client_admission_diagnosis.json`
- `public_client_admission_diagnosis.md`

Unlike `scripts\join_live_pair_lane.ps1`, these public-mode helpers are not lab lane join tools. They are specifically for `sv_lan 0` public admission and only report success when the server logs a real human connect or `entered the game`.

Compare the available public admission paths like this:

```bat
scripts\compare_public_admission_paths.bat -ServerAddress 127.0.0.1 -ServerPort 27015 -PublicServerOutputRoot D:\DEV\CPP\HL-Bots\lab\logs\public_server\<run-root>
```

This comparison helper writes:

- `public_admission_path_comparison.json`
- `public_admission_path_comparison.md`

It compares the Steam app-launch path, the Steam `steam://connect/...` URI path, and the direct `hl.exe` path when those paths are available on the current machine. Use it when you need to know which public admission path is best, not when you need to join a control or treatment lab lane.

The compatibility alias is:

```bat
scripts\compare_public_client_admission_paths.bat -ServerAddress 127.0.0.1 -ServerPort 27015 -PublicServerOutputRoot D:\DEV\CPP\HL-Bots\lab\logs\public_server\<run-root>
```

Run the consolidated Steam/public admission drill like this:

```bat
scripts\run_public_steam_admission_drill.bat -ServerAddress 127.0.0.1 -ServerPort 27015 -PublicServerOutputRoot D:\DEV\CPP\HL-Bots\lab\logs\public_server\<run-root>
```

The drill reuses the Steam environment audit, runs the bounded path comparison in this order, and writes one consolidated result:

- `steam-native-applaunch`: starts Half-Life through `steam.exe -applaunch 70 ...`
- `steam-connect-uri`: asks Steam to handle `steam://connect/<host>:<port>`
- `direct-hl-exe-connect`: starts the discovered `hl.exe` directly with `+connect`

The drill writes:

- `public_steam_admission_drill.json`
- `public_steam_admission_drill.md`

Read `machine_local_blocker_classification` first. `steam-session-not-ready` points at local Steam/Half-Life session state. `steam-app-launch-path-broken` means Steam accepted a launch attempt but no `hl.exe` materialized. `hl-client-launches-but-public-admission-never-starts` means `hl.exe` appeared locally but HLDS never saw a non-BOT connect. `public-admission-blocked-before-server-connect` means Steam/public admission evidence failed before server connect. `server-connect-seen-but-entered-game-not-seen` means the blocker moved later than raw server connect. `public-admission-working` is the only verdict that proves enough server-side human admission to spend a full public human-trigger rerun immediately.

Run the Steam session preflight before spending more public admission attempts:

```bat
scripts\preflight_public_steam_session.bat -ServerPort 27015
```

It writes `public_steam_session_preflight.json` and `.md`. `steam-session-blocked-cm-failure` means Steam and Half-Life are discoverable, but Steam logs still show CM/no-connection evidence that can block public admission before HLDS ever sees a human. `steam-session-blocked-app-missing` means app 70 is not fully present locally. `steam-session-ready-with-warnings` means the prerequisites mostly exist, but the helper did not see a clean online/session signal.

Test concrete launch variants against a live public server like this:

```bat
scripts\test_public_hldm_launch_variants.bat -ServerAddress 127.0.0.1 -ServerPort 27015 -PublicServerOutputRoot D:\DEV\CPP\HL-Bots\lab\logs\public_server\<run-root>
```

It writes `public_hldm_launch_variants.json` and `.md`, comparing `steam-native-applaunch`, `steam-connect-uri`, `steam-run-connect-uri`, and `direct-hl-exe-connect`. `steam-app-launch-path-broken` means all available Steam-backed variants issued a launch but no new `hl.exe` appeared. `hl-client-launches-but-public-admission-never-starts` means a local client process appeared, but no server-side non-BOT connect followed.

If local Steam/client admission remains blocked, print the external validation plan:

```bat
scripts\print_public_external_validation_plan.bat -ServerAddress 127.0.0.1 -ServerPort 27015 -PublicServerOutputRoot D:\DEV\CPP\HL-Bots\lab\logs\public_server\<run-root>
```

It writes `public_external_validation_plan.json` and `.md` with the server target, expected public status states, server-log evidence to watch, bot disconnect/repopulate checks, and artifacts to save from a real external Half-Life client.

Preflight external access before asking another client to join:

```bat
scripts\preflight_public_external_access.bat -Port 27015 -AdvertisedAddress <public-or-lan-address>
```

It writes `public_external_access_preflight.json` and `.md`. The helper reports the selected local address and port, LAN addresses, any visible `hlds.exe` process, local UDP listener evidence, public status/RCON freshness when `public_server_status.json` is available, and a NAT/firewall warning. It cannot prove Internet-side UDP reachability from inside the server machine.

Run the network exposure preflight before tester handoff:

```bat
scripts\preflight_public_network_exposure.bat -Port 27015 -AdvertisedAddress <public-or-lan-address> -PublicServerOutputRoot D:\DEV\CPP\HL-Bots\lab\logs\public_server\<run-root>
```

It writes `public_network_exposure_preflight.json` and `.md`. It checks the selected UDP port, visible `hlds.exe` process, local public status/RCON evidence, UDP listener evidence when available, LAN IP candidates, relevant Windows Firewall rules, whether a matching enabled inbound allow rule exists, and the limits of same-machine testing. It also reports `readiness_classification`: `ready-for-external-test` means local server/RCON/UDP/firewall prerequisites are present, `ready-with-warnings` means the live server is locally usable but at least one exposure prerequisite is unverified, and `blocked` means the local public server path itself is not ready. It never claims Internet reachability unless an actual external check proves it.

Use the firewall helper in dry-run mode first:

```bat
scripts\configure_public_hlds_firewall.bat -Port 27015
```

It writes `public_hlds_firewall_check.json` and `.md`, plus legacy `public_hlds_firewall_rule.json` / `.md` aliases. If the shell is not elevated, the verdict is not treated as verified and the helper prints the exact elevated command to run. It does not create, delete, or broaden firewall rules unless `-Apply` is explicitly supplied from an elevated shell.

Explicit dry-run and elevated apply examples:

```bat
scripts\configure_public_hlds_firewall.bat -Port 27015 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure_public_hlds_firewall.ps1 -Port 27015 -HldsExePath D:\DEV\CPP\HL-Bots\lab\hlds\hlds.exe -RuleName "HLDM Public Crossfire UDP 27015" -Apply
```

`firewall-apply-blocked-not-elevated` means `-Apply` was requested from a non-elevated shell and no firewall change was made. Open PowerShell as Administrator and rerun the printed command if you intend to create or update the narrow UDP rule.

Prepare a tester handoff package:

```bat
scripts\prepare_external_tester_package.bat -Map crossfire -Port 27015 -AdvertisedAddress <public-or-lan-address> -ExpectedExternalTesterName <name>
```

It writes `external_tester_package.json`, `external_tester_package.md`, and `external_tester_join_steps.txt`. Send the tester the join steps: the expected client command is `connect <address>:<port>`, they should stay connected through the hold window, leave when the operator asks, and report timeout, version, password, disconnect, or other client-side errors.

Run the external real-client human-trigger watcher like this:

```bat
scripts\run_public_external_human_trigger_validation.bat -Map crossfire -Port 27015 -BotCountWhenEmpty 4 -BotSkillWhenEmpty 3 -AdvertisedAddress <public-or-lan-address> -ExpectedExternalTesterName <name> -SkipSteamCmdUpdate -SkipMetamodDownload
```

The watcher starts public mode unless `-AttachToExistingServer` is supplied. It writes:

- `public_external_human_trigger_validation.json`
- `public_external_human_trigger_validation.md`
- `public_external_join_instructions.txt`
- `public_external_join_instructions.md`
- `public_external_join_instructions.json`

Share the join instruction file with the external tester. The client command is `connect <address>:<port>`. The tester should join, stay connected through the hold window, leave when asked, and report any client-side error text.

The external watcher uses the same source of truth as public mode: GoldSrc `status` over RCON, surfaced through `public_server_status.json`. It records these lifecycle states when evidence exists:

- `bots-active-empty-server`
- `waiting-external-human`
- `external-human-admitted`
- `bots-disconnected-humans-present`
- `humans-hold-bots-out`
- `waiting-empty-server-repopulate`
- `bots-repopulated-empty-server`
- `validation-timeout`
- `validation-blocked-no-external-admission`

The verdict is `external-human-trigger-validated` only after a real non-BOT human is observed by authoritative server status, bots are removed while the human remains, and bots return after the server becomes empty. `external-human-admission-not-observed` means the watcher ran but no external human reached authoritative server status. `public-server-not-reachable-locally` means local public status/RCON was not available enough to validate anything. Local Steam admission remains a separate machine-local diagnostic path; do not treat local Steam CM failure as evidence against the public bot policy.

Audit one Steam-backed public admission failure like this:

```bat
scripts\audit_steam_public_admission.bat -ComparisonJsonPath D:\DEV\CPP\HL-Bots\lab\logs\public_server\admission_path_comparisons\<comparison-root>\public_admission_path_comparison.json
```

This audit helper writes:

- `steam_public_admission_audit.json`
- `steam_public_admission_audit.md`

Audit the local Steam + Half-Life public admission environment like this:

```bat
scripts\audit_public_steam_environment.bat -ServerAddress 127.0.0.1 -ServerPort 27015 -PublicServerOutputRoot D:\DEV\CPP\HL-Bots\lab\logs\public_server\<run-root>
```

This environment helper writes:

- `public_steam_environment_audit.json`
- `public_steam_environment_audit.md`

`steam-admission-failed-before-server-connect` means the Steam-backed path started locally but the Steam admission chain failed before the HLDS log ever saw a real human `connected`.

`server-connect-seen-no-entered-game` means the HLDS log already saw a real human connect, but the session still never crossed into a saved non-BOT `entered the game` event.

Validate the human-trigger path like this:

```bat
scripts\validate_public_human_trigger.bat -Map crossfire -BotCountWhenEmpty 4 -BotSkillWhenEmpty 3 -Port 27015 -SkipSteamCmdUpdate -SkipMetamodDownload
```

The validator uses the same authoritative human-count source as public mode itself: GoldSrc `status` over RCON. It records the public policy states:

- `waiting-human-join-grace`
- `bots-active-empty-server`
- `bots-disconnected-humans-present`
- `waiting-empty-server-repopulate`
- `bots-repopulated-empty-server`

The validator also records which public admission path was attempted first, whether it fell back to Steam URI or direct `hl.exe`, and the matching `public_client_admission_diagnosis.json` path for each attempt.

If the local public join still fails before server admission, the validator preserves the narrowest blocker instead of guessing. In this environment that means checking the client `qconsole.log`, the Steam per-port `connection_log_<port>.txt`, the public admission diagnosis, the Steam admission drill, and the public server status history before claiming the human-trigger path is really broken.

The full public human-trigger validation is complete only when one validator run records:

- a real authoritative human admission
- `bots-disconnected-humans-present` while that human remains
- `bots-repopulated-empty-server` after humans leave

`blocked-before-server-admission` means the local client launch path never crossed the authoritative server-side human boundary. If the environment audit ends `steam-environment-blocked-before-admission` and the best Steam-backed comparison path still fails before server connect, the remaining blocker is likely external to repo-side public server logic on that machine.

Treat the public bot policy as done for product-minimum purposes when empty-server public mode is working, advanced AI remains off by default, and the drill or launch-variant helper still stops before a non-BOT server connect. A full `validate_public_human_trigger.ps1` rerun is justified when the drill or variant report returns `public-admission-working`, or when `server-connect-seen-but-entered-game-not-seen` gives you a fresh reason to spend a longer validator window. It is not justified for `steam-session-blocked-cm-failure`, `steam-session-not-ready`, `steam-app-launch-path-broken`, `hl-client-launches-but-public-admission-never-starts`, or `public-admission-blocked-before-server-connect` until the local blocker changes.

Current local status on `main`:

- empty-server public mode is working on `crossfire`
- advanced AI balance remains off by default
- the prompt-75 Steam session preflight classifies this machine as `steam-session-blocked-cm-failure`
- the prompt-75 launch-variant run materialized `hl.exe` through Steam-backed and direct paths, but still stopped at `hl-client-launches-but-public-admission-never-starts` before any non-BOT server connect
- the prompt-76 external watcher confirmed `bots-active-empty-server` on `crossfire` with 0 humans, 4 bots, target 4, and advanced AI off, then reported `external-human-admission-not-observed` because no external client joined during the wait
- the prompt-77 network exposure preflight confirmed local public status/RCON and UDP listener evidence for the live public server but classified firewall enumeration as `public-network-exposure-firewall-query-blocked` because Windows returned access denied; the tester package was produced for `connect 192.168.0.102:27041`
- the prompt-78 firewall helper produced `firewall-check-not-verified-not-elevated` from the current shell, printed the elevated `-Apply` command for the narrow UDP rule, refreshed network exposure on `192.168.0.102:27043`, and the external watcher again reported `external-human-admission-not-observed`
- the prompt-79 elevation gate still found a non-elevated shell, so firewall apply remains blocked locally unless an Administrator shell runs the printed narrow UDP rule command
- the prompt-80 elevation gate again found a non-elevated shell, so the firewall helper recorded `firewall-apply-blocked-not-elevated`; public network preflight and the external watcher should be rerun after the printed Administrator command is applied
- the prompt-73 baseline showed both Steam-backed paths still failing before any real server-side `connected` event, while direct `hl.exe` could materialize locally but still did not create authoritative public admission under `sv_lan 0`

To opt into the existing advanced path later, use `-EnableAdvancedAIBalance`. The public runner keeps that disabled by default so the product minimum does not depend on the Python sidecar or the evidence stack.

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
- `scripts\run_guided_live_pair_session.ps1` is the operator-facing wrapper over preflight, the pre-run mission brief, the pair runner, the live monitor, review, shadow review, scoring, registration, registry summary, responsive-trial gate, the next-live planner, the outcome dossier, and the final session docket.
- `scripts\run_current_live_mission.ps1` is the mission-driven launcher. It reads the latest mission brief by default, enforces conservative drift policy before launch, and records `guided_session\mission_execution.json` / `.md` so later closeout can tell whether the operator actually launched the current mission.
- `scripts\assess_latest_session_recovery.ps1` is the interruption and recovery classifier. It inspects the latest pair pack or an explicit pair root, writes `session_recovery_report.json` / `.md`, says whether the session is complete, interrupted, salvageable, or rerun-only, and emits an exact salvage command when the session is recoverable.
- `scripts\reconcile_pair_metrics.ps1` is narrower than the counted-pair review helper. The review helper answers whether a counted pair should still count at all; the reconciliation helper assumes that counted/manual-review result, recomputes canonical control/treatment metrics from the saved pair and lane evidence, and only refreshes secondary artifacts when that is safe and auditable.
- `scripts\finalize_interrupted_session.ps1` is the conservative salvage helper. It reads the recovery assessment first, refuses pre-sufficiency and manual-review branches, reruns only the recoverable closeout steps, writes `session_salvage_report.json` / `.md`, and keeps rehearsals or other non-grounded sessions excluded from promotion even when salvage completes structurally.
- `scripts\plan_next_live_session.ps1` is the read-only promotion-gap planner. It reuses the certified registry summary and responsive gate outputs to produce `next_live_plan.json` and `next_live_plan.md` with the exact deficits still blocking responsive and the concrete objective for the next live session.
- `scripts\prepare_next_live_session_mission.ps1` is the pre-run operator brief. It reuses the current responsive gate, the next-live planner, and the latest outcome dossier context to produce `next_live_session_mission.json` and `next_live_session_mission.md` with the exact thresholds, stop condition, failure conditions, and mission statement for the very next live run.
- each paired run writes `pair_summary.json`, `pair_summary.md`, `comparison.json`, `comparison.md`, `control_join_instructions.txt`, `treatment_join_instructions.txt`, and the nested lane/session-pack folders.
- each guided paired run also writes `session_outcome_dossier.json` / `.md` and `mission_attainment.json` / `.md` under the pair root, snapshots the pre-run mission under `guided_session\mission\`, writes `guided_session\mission_execution.json` / `.md`, records a thin `guided_session\session_state.json` marker for interruption assessment, and points the final guided docket back at all four layers so the operator can compare "what was the target before launch?" against "what was actually launched?" against "what counted after the run?" and "did that actually achieve the mission?".
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
- `human_presence_timeline.ndjson` or the shorter fallback alias `human_timeline.ndjson` when deep bounded-probe roots would otherwise exceed the classic Windows path limit
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

For the next real conservative human pair session, prefer the mission-driven runner first:

```powershell
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1
```

Inspect the exact mission-derived launch without starting a session like this:

```powershell
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1 -DryRun
```

Rehearse the same guided workflow end to end without a real human participant like this:

```powershell
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1 -RehearsalMode -RehearsalFixtureId strong_signal_keep_conservative -RehearsalStepSeconds 2 -AutoStopWhenSufficient -MonitorPollSeconds 1
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
- pre-run mission briefing remains `scripts\prepare_next_live_session_mission.ps1`
- responsive promotion gating remains `scripts\evaluate_responsive_trial_gate.ps1`

Read the final guided docket like this:

- `final_session_docket.json`: machine-readable final state for the pair, monitor, post-run outputs, and operator recommendation flags
- `final_session_docket.md`: concise human-facing end-of-run pointer that says whether the session was sufficient and where to open the consolidated outcome dossier next
- `next_live_session_mission.json` / `next_live_session_mission.md`: the pre-run target artifact that says exactly what the next session must accomplish before it starts
- `session_outcome_dossier.json` / `session_outcome_dossier.md`: the consolidated post-session answer that merges scorecard, certification, latest-session delta, responsive gate, and next-live planning into one artifact
- `mission_attainment.json` / `mission_attainment.md`: the mission closeout that compares the saved mission brief against target-by-target actuals and says whether the session met its mission in the operational, grounded, and promotion-impact senses

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

## Outcome Dossier

Use `scripts\build_latest_session_outcome_dossier.ps1` immediately after a pair session when the operator wants one artifact instead of mentally merging the scorecard, certification, delta, gate, and planner outputs.

- it writes `session_outcome_dossier.json` and `session_outcome_dossier.md` into the pair root
- by default it finds the latest pair pack; pass `-PairRoot .\lab\logs\eval\pairs\<pair-pack>` when you want a specific saved pair
- it reuses the existing scorecard, shadow review, certification, and latest-session delta helpers instead of inventing a second decision engine
- it includes the registry/gate/planner before-vs-after state that comes from the existing latest-session delta analysis
- it is not a replacement for scorecard alone: scorecard still answers how one pair behaved
- it is not a replacement for certification alone: certification still answers whether one pair counts toward promotion
- it is not a replacement for the next-live planner: the planner still defines the explicit promotion gap and the next session target
- `what changed because of this session?` is the compact delta block. Read it as evidence accounting first: grounded sessions, grounded too-quiet evidence, strong-signal evidence, responsive blockers, next objective movement, and gate movement
- non-grounded, rehearsal, synthetic, no-human, weak-signal, and otherwise excluded sessions can legitimately leave the dossier in a no-impact state. That is the honest answer when the real promotion gap did not move

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

## Next Live Session Mission Brief

Use `scripts\prepare_next_live_session_mission.ps1` immediately before the next real live session when the operator needs one concrete pre-run target instead of piecing it together from the planner, gate, and latest dossier manually.

- it writes `next_live_session_mission.json` and `next_live_session_mission.md` under `lab\logs\eval\registry\`
- it now also carries launcher defaults such as the default pair output root, `Release|Win32`, and default skip-flag values so the mission runner can compare launch drift against an explicit baseline instead of guessing
- it reuses the current registry summary, responsive gate, and next-live planner outputs instead of creating a second decision engine
- it also reads the latest available live outcome dossier when one exists, so the mission can state whether the project is still in the same blocked state or is coming off a recent non-grounded run
- it is narrower than the planner: the planner explains the whole promotion gap, while the mission brief narrows that into the exact next-session target, exact thresholds, exact stop condition, and exact ways the session can still fail to count
- it is earlier than the outcome dossier: the dossier explains what the last session changed after the run, while the mission brief explains what the next session must accomplish before the run
- it stays conservative until certified grounded evidence exists; a blocked gate or non-grounded latest dossier does not get softened into speculative responsive language
- it aligns directly with the live monitor: the mission's stop condition is the existing `sufficient-for-tuning-usable-review` / `sufficient-for-scorecard` bar, not a new mission-only rule

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\prepare_next_live_session_mission.ps1
```

Or with the thin wrapper:

```bat
scripts\prepare_next_live_session_mission.bat
```

## Current Live Mission Runner

Use `scripts\run_current_live_mission.ps1` when the question is not only "what should the next live session do?" but "launch exactly that mission, or tell me precisely why not."

- it reads `lab\logs\eval\registry\next_live_session_mission.json` by default, or accepts `-MissionPath` when you want a specific saved brief
- it launches the existing `scripts\run_guided_live_pair_session.ps1` stack instead of creating a parallel launcher
- it writes a preview `mission_execution.json` / `.md` in dry-run mode and writes the final launch record under `guided_session\mission_execution.json` / `.md` after a real or rehearsal-backed run starts
- it compares mission vs requested launch for map, bot count, bot skill, control port, treatment port, treatment profile, human-signal thresholds, patch-while-human-present target, post-patch observation target, skip flags, and output roots
- output-root drift is recorded and allowed by default because it does not change the experiment semantics; safe port drift requires `-AllowSafePortOverride`
- mission-changing drift such as map changes, bot-count changes, treatment-profile changes, or weakened thresholds is blocked unless `-AllowMissionOverride` is supplied
- if the mission still says `conservative` and the responsive gate is closed, switching to `responsive` is blocked by default; even with `-AllowMissionOverride`, the run stays mission-divergent and mission-attainment will not present it as mission-perfect
- `-DryRun` prints the mission path, exact launch parameters, exact guided-runner command, and whether drift would be blocked, warned, or allowed without starting the session
- `-PrintCommandOnly` is the same no-launch policy path when you only need the exact command text
- mission-attainment later reads `mission_execution.json`; if the launch diverged from the mission in an experiment-changing way, the closeout becomes `mission-divergent-run` instead of a false mission-met result

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1 -DryRun
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1 -DryRun -ControlPort 27018 -TreatmentPort 27019 -AllowSafePortOverride
powershell -NoProfile -File .\scripts\run_current_live_mission.ps1 -DryRun -TreatmentProfile responsive -AllowMissionOverride
```

Or with the thin wrapper:

```bat
scripts\run_current_live_mission.bat
```

## Mission Attainment

Use `scripts\evaluate_latest_session_mission.ps1` immediately after a completed session when the question is not only "what happened?" but "did this run achieve the exact mission it was started for?"

- it writes `mission_attainment.json` and `mission_attainment.md` into the pair root
- by default it evaluates the latest pair pack; pass `-PairRoot .\lab\logs\eval\pairs\<pair-pack>` when you want a specific saved pair
- it requires the mission snapshot that was used before launch; if the pair predates mission snapshots, it fails honestly instead of fabricating a result
- it reuses the saved mission brief, mission execution record, live monitor status, scorecard, grounded certification, outcome dossier, and latest-session delta instead of inventing another scoring engine
- it is different from the mission brief: the mission brief is pre-run and says what must happen, while mission attainment is post-run and says whether that exact target was met
- it is different from the live monitor: the live monitor answers whether the operator can stop safely during the run, while mission attainment compares all mission targets against the final captured evidence after the run
- it is different from the outcome dossier: the dossier is the broad post-run consolidation layer, while mission attainment is the narrow mission-closeout layer anchored to one saved mission snapshot
- it now also checks whether the launch itself stayed mission-compliant; mission-divergent launches return `mission-divergent-run` even if the captured evidence otherwise looks strong
- the `target_results` block is the exact target-vs-actual view; for each mission target read `target_value`, `actual_value`, `met`, and `explanation` literally
- `mission-met-but-no-promotion-impact` means the run satisfied the monitor-facing mission thresholds, but the evidence still did not count toward or move the real promotion ledger
- `mission-met-and-gap-reduced` means the run counted as grounded evidence and shrank at least one real promotion-gap component without changing the next objective or responsive gate
- `mission-met-and-next-objective-advanced` means the run counted as grounded evidence and changed the next objective, responsive gate, or both
- rehearsal, synthetic, no-human, weak-signal, insufficient-data, and other non-grounded sessions can still look operationally successful while failing mission attainment in the promotion sense; the helper must say that explicitly and keep the next live mission conservative

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

Use `scripts\assess_latest_session_recovery.ps1` when the question is not only "did the mission succeed?" but "is the latest pair complete, interrupted, recoverable, or rerun-only?"

- it writes `session_recovery_report.json` and `session_recovery_report.md` into the assessed pair root
- by default it inspects the latest pair pack; pass `-PairRoot .\lab\logs\eval\pairs\<pair-pack>` when you want a specific saved pair
- it checks the mission snapshot, mission execution, monitor status, pair summary, comparison, scorecard, shadow review, grounded certificate, latest-session delta, next-live planner output, outcome dossier, mission attainment, final docket, and guided `session_state.json` when present
- it distinguishes conservative recovery verdicts such as `session-complete`, `session-interrupted-before-sufficiency`, `session-interrupted-after-sufficiency-before-closeout`, `session-interrupted-during-post-pipeline`, `session-partial-artifacts-recoverable`, and `session-nonrecoverable-rerun-required`
- when the pair is recoverable, the report also includes `recommended_salvage_command` so the operator can run the exact supported salvage path instead of guessing which closeout helpers to rerun
- it keeps registry and promotion handling honest: incomplete sessions stay excluded from promotion logic, rehearsal or workflow-validation sessions stay non-promoting even when structurally complete, and missing mission-critical artifacts force manual review instead of silent overclaiming
- it is different from mission attainment: mission attainment asks whether the run met its saved mission, while recovery assessment asks whether the run finished cleanly enough to trust, salvage, or rerun
- it is different from the outcome dossier: the dossier explains what changed because of a completed session, while recovery assessment decides whether the session is complete enough to trust that closeout at all

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

Use `scripts\finalize_interrupted_session.ps1` only after recovery assessment says the saved pair is genuinely recoverable without replaying the live run.

- it writes `session_salvage_report.json` and `session_salvage_report.md` into the target pair root
- it only proceeds for recoverable branches such as `session-interrupted-after-sufficiency-before-closeout`, `session-interrupted-during-post-pipeline`, or `session-partial-artifacts-recoverable`
- it refuses pre-sufficiency, nonrecoverable, or manual-review-only branches instead of pretending those runs can be salvaged
- it reuses the honest post-run stack to rebuild only the closeout layer: dossier, registration, registry summary, responsive gate, next-live plan, mission attainment, and guided-session metadata when needed
- it is different from rerunning the mission: salvage preserves the saved pair evidence and finishes the paperwork around that exact run, while rerunning the mission spends a new live session and creates a new pair root
- a salvaged session may still remain `workflow-validation-only`, non-grounded, or excluded from promotion logic; salvage can complete the artifact stack, but it cannot manufacture promotion-counting evidence

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\finalize_interrupted_session.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack>
```

Or with the thin wrapper:

```bat
scripts\finalize_interrupted_session.bat .\lab\logs\eval\pairs\<pair-pack>
```

## Mission Continuation Controller

Use `scripts\continue_current_live_mission.ps1` when the question after a failure is not only "what does recovery assessment say?" but "should I salvage, rerun, leave the completed session alone, or stop for manual review?"

- it writes `mission_continuation_decision.json` and `mission_continuation_decision.md` into the assessed pair root
- by default it previews the decision only; add `-Execute` only when you want the controller to actually run salvage or start a rerun
- it reuses `scripts\assess_latest_session_recovery.ps1` for the verdict, `scripts\finalize_interrupted_session.ps1` for recoverable salvage branches, and `scripts\run_current_live_mission.ps1` for reruns instead of introducing a second recovery engine
- it maps complete sessions to `session-already-complete-no-action` or `session-already-complete-review-only`, recoverable interrupted sessions to `salvage-interrupted-session`, pre-sufficiency or nonrecoverable sessions to `rerun-current-mission` or `rerun-current-mission-with-new-pair-root`, and inconsistent mission-critical states to `manual-review-required` or `blocked-no-mission-context`
- it reuses the saved mission snapshot when available so reruns stay mission-compliant; when that snapshot is unavailable but the current mission brief is still usable, it marks the rerun as mission-recovered instead of pretending it is the exact interrupted launch
- it points directly to the saved mission snapshot, mission execution artifact, recovery report, salvage report, final docket, mission attainment, and any rerun pair root so later audit stays easy
- it stays conservative about promotion: structurally complete rehearsal, synthetic, weak-signal, or otherwise non-grounded sessions stay excluded from promotion even when the controller says no rerun is needed
- it is different from recovery assessment alone: recovery classifies the session, while the continuation controller decides and optionally executes the supported next step
- it is different from salvage alone: salvage only finishes recoverable closeout, while the continuation controller decides whether salvage is appropriate at all or whether the right answer is no action, rerun, or manual review

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

Use `scripts\run_mission_continuation_rehearsal.ps1` before the first human-rich conservative session when you want one end-to-end proof that mission launch, failure handling, recovery assessment, continuation choice, and promotion-safe closeout all behave correctly together.

- it writes `continuation_rehearsal_report.json` and `continuation_rehearsal_report.md` under each rehearsed branch, plus `rehearsal_suite_summary.json` and `rehearsal_suite_summary.md` under the suite root
- it reuses the real mission-driven stack instead of inventing a fake harness: `run_current_live_mission.ps1`, `inject_pair_session_failure.ps1`, `assess_latest_session_recovery.ps1`, `continue_current_live_mission.ps1`, and `finalize_interrupted_session.ps1`
- supported rehearsal branches include `already-complete`, `after-sufficiency-before-closeout`, `during-post-pipeline`, `before-sufficiency`, `missing-mission-snapshot`, and the optional `partial-artifacts-recoverable`
- success means the controller chooses the honest branch: no action for already-complete, salvage for recoverable interrupted branches, rerun for pre-sufficiency branches, and manual review when mission-critical context is missing
- the failure injector is rehearsal-safe by default and keeps copied evidence labeled `rehearsal`, `synthetic_fixture`, and `validation_only`; it does not mutate a real live pair unless someone explicitly asks for unsafe in-place mutation
- salvaged or rerun rehearsal branches must stay excluded from promotion, must keep the responsive gate closed, and must keep registry activity under the branch-local rehearsal outputs such as `guided_session\registry\`
- this is different from the real live continuation path: the rehearsal proves the workflow wiring and failure policy, but it does not create grounded evidence or justify changing the live treatment profile

Run the full suite or a selected branch like this:

```powershell
powershell -NoProfile -File .\scripts\run_mission_continuation_rehearsal.ps1
powershell -NoProfile -File .\scripts\run_mission_continuation_rehearsal.ps1 -FailureModes during-post-pipeline
```

If you already have a completed rehearsal base pair and want to avoid launching another rehearsal run, pass it explicitly:

```powershell
powershell -NoProfile -File .\scripts\run_mission_continuation_rehearsal.ps1 -BasePairRoot .\lab\logs\eval\continuation_rehearsal\<suite>\runtime\<pair-pack> -FailureModes already-complete,before-sufficiency,missing-mission-snapshot
```

Or use the thin wrapper:

```bat
scripts\run_mission_continuation_rehearsal.bat -FailureModes already-complete
```

## Recovery Branch Matrix

Use `scripts\run_recovery_branch_matrix.ps1` when you want one consolidated recovery-readiness answer instead of reading individual rehearsal branch reports.

- it runs the required continuation branches as one suite: `already-complete`, `after-sufficiency-before-closeout`, `during-post-pipeline`, `partial-artifacts-recoverable`, `before-sufficiency`, and `missing-mission-snapshot`
- it stays thin by reusing `inject_pair_session_failure.ps1`, `run_mission_continuation_rehearsal.ps1`, `assess_latest_session_recovery.ps1`, `finalize_interrupted_session.ps1`, and `continue_current_live_mission.ps1`
- it writes `recovery_branch_matrix.json` and `recovery_branch_matrix.md` with per-branch expected versus actual recovery verdicts, continuation actions, salvage or rerun outcomes, structural-completeness results, and promotion-safety checks
- it also writes `recovery_readiness_certificate.json` and `recovery_readiness_certificate.md` with one operator verdict: `ready-for-first-grounded-conservative-session`, `ready-with-known-gaps`, or `blocked`
- success means every required branch matches the expected conservative outcome, salvaged rehearsal branches keep their registry under branch-local outputs such as `guided_session\registry\`, rehearsal evidence stays excluded from promotion, and the responsive gate remains closed on rehearsal-only evidence
- readiness here is operational only. It proves the failure-handling workflow is wired correctly; it does not add grounded tuning evidence and it does not justify changing the live treatment profile

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\run_recovery_branch_matrix.ps1
```

Or with the thin wrapper:

```bat
scripts\run_recovery_branch_matrix.bat
```

Read the outputs in this order:

- `recovery_readiness_certificate.md` for the operator-facing go or no-go verdict
- `recovery_branch_matrix.md` for branch-by-branch evidence and any failure explanation
- branch-local `continuation_rehearsal_report.md` files only when the matrix shows a gap that needs inspection

## First Grounded Conservative Attempt

Use `scripts\run_first_grounded_conservative_attempt.ps1` when the goal is no longer workflow rehearsal or recovery validation but the actual first conservative live evidence capture attempt.

- it stays thin by reusing `prepare_next_live_session_mission.ps1`, `run_current_live_mission.ps1`, `assess_latest_session_recovery.ps1`, `continue_current_live_mission.ps1`, `build_latest_session_outcome_dossier.ps1`, and `evaluate_latest_session_mission.ps1`
- it preserves `conservative` as the treatment profile and keeps the no-AI control lane unchanged
- it writes `first_grounded_conservative_attempt.json` and `first_grounded_conservative_attempt.md` into the final pair root when a pair exists
- it answers the milestone questions directly: whether the first grounded conservative session was captured, whether the session counted toward promotion, what changed in the grounded-evidence state, and why the attempt failed if it stayed non-grounded
- if the live run interrupts or closes out partially, it uses the supported continuation path instead of inventing a second recovery flow
- if the environment still does not provide real human-rich signal, the helper still runs the real mission path as far as possible and reports `conservative-session-insufficient-human-signal` or another honest non-success verdict instead of fabricating grounded evidence
- it differs from `run_current_live_mission.ps1`: the mission runner launches the session, while this helper also wraps the honest after-action closeout and milestone summary for the first grounded conservative capture attempt
- even after a clean attempt, `responsive` must stay closed unless the real grounded evidence and gate outputs actually change

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\run_first_grounded_conservative_attempt.ps1
```

For an explicit validation-only fallback in an environment without a real player, keep it clearly mission-divergent and say so with `-AllowMissionOverride`:

```powershell
powershell -NoProfile -File .\scripts\run_first_grounded_conservative_attempt.ps1 -AllowMissionOverride -DurationSeconds 20 -HumanJoinGraceSeconds 10 -SkipSteamCmdUpdate -SkipMetamodDownload
```

That fallback is only for orchestration validation. It must still end as non-grounded and must not be confused with the true first grounded conservative capture attempt.

Or with the thin wrapper:

```bat
scripts\run_first_grounded_conservative_attempt.bat
```

## Client-Assisted Grounded Conservative Attempt

Use `scripts\run_human_participation_conservative_attempt.ps1` when `hl.exe` is available locally and the goal is not only to launch the first grounded conservative attempt, but to turn that availability into an actual control-then-treatment human-participation run.

- it stays thin by reusing `discover_hldm_client.ps1`, `join_live_pair_lane.ps1`, and `run_first_grounded_conservative_attempt.ps1` instead of creating a second mission or closeout engine
- it launches the existing first-grounded conservative attempt in the background, waits for the pair root to appear, then auto-joins the control lane first and the treatment lane second when those ports become active
- on the sequential auto-join path it now runs both a control-first switch gate and a treatment-hold gate, so the helper keeps the local client in control until control really clears the mission thresholds and then keeps the client in treatment until grounded patch evidence is actually ready
- it writes `human_participation_conservative_attempt.json` and `human_participation_conservative_attempt.md` into the final pair root when a pair exists
- it records exact control and treatment join helper commands, the control-first switch helper command and verdict, the treatment-hold helper command and verdict, whether auto-launch was attempted, whether the saved pair evidence shows real human presence in each lane, and whether the run stayed sequential, interrupted, or non-grounded
- it never treats `hl.exe` launch by itself as proof of grounded evidence; the report only credits lane participation when the saved pair evidence shows human snapshots or human-presence time
- it differs from `run_first_grounded_conservative_attempt.ps1`: the first-grounded helper summarizes the mission and closeout result, while the client-assisted helper adds local-client discovery, lane-join execution, and explicit human-participation tracking on top of that same result

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\run_human_participation_conservative_attempt.ps1
```

Or with the thin wrapper:

```bat
scripts\run_human_participation_conservative_attempt.bat
```

## Control-First Switch Gate

Use `scripts\guide_control_to_treatment_switch.ps1` when the immediate question is not "is the whole pair sufficient yet?" but "is it finally safe to leave control?"

- it reads the saved mission thresholds first, then combines pair artifacts and the guided monitor history to answer whether the operator should stay in control, switch to treatment, keep waiting in treatment, or accept that the pair timed out non-grounded
- it reports the exact remaining control-side blocker such as "short by 1 snapshot and 20 seconds", which is the practical fix when a second grounded conservative attempt fails only because control was left too early
- it differs from `monitor_live_pair_session.ps1`: the broader live monitor answers whether the whole grounded evidence bar is satisfied, while this helper answers whether the control-to-treatment handoff is justified yet

Use it like this:

```powershell
powershell -NoProfile -File .\scripts\guide_control_to_treatment_switch.ps1 -PairRoot <pair-root> -Once
powershell -NoProfile -File .\scripts\guide_control_to_treatment_switch.ps1 -UseLatest
```

## Treatment-Hold Patch Window Gate

Use `scripts\guide_treatment_patch_window.ps1` when control is already good enough and the immediate question becomes "is treatment finally safe to leave, or what exact grounded patch evidence is still missing?"

- it stays narrow: the broader live monitor answers whether the whole pair is sufficient, while this helper answers whether the treatment lane has actually captured grounded patch evidence yet
- it reads the saved mission thresholds, reuses the control-first switch report, and then focuses on treatment-side grounded conditions only: human snapshots, human presence seconds, counted patch-while-human-present events, and the post-patch observation window
- it reports the exact remaining treatment-side blocker such as "still short by 2 counted patch-while-human-present events" or "stay for another 20 post-patch seconds"
- if a patch was merely applied during the human window from an earlier pre-human recommendation, it records that timestamp explicitly without pretending that it satisfied the grounded human-present patch event requirement
- `treatment-grounded-ready` means treatment is safe to leave; anything else means the operator should stay in treatment or accept that the pair already timed out non-grounded

Use it like this:

```powershell
powershell -NoProfile -File .\scripts\guide_treatment_patch_window.ps1 -PairRoot <pair-root> -Once
powershell -NoProfile -File .\scripts\guide_treatment_patch_window.ps1 -UseLatest
```

## Sequential Conservative Phase Flow

Use `scripts\guide_conservative_phase_flow.ps1` when the operator needs one authoritative live answer instead of manually juggling the separate control and treatment helpers.

- it stays thin by reusing the existing control-first and treatment-hold logic instead of inventing a third threshold engine
- it reports one current phase, one next operator action, and the exact remaining blocker for that phase
- `phase-control-stay` means remain in the no-AI control lane
- `phase-control-ready-switch-now` means control has cleared and it is safe to join treatment
- `phase-treatment-waiting-for-human-signal`, `phase-treatment-waiting-for-patch`, and `phase-treatment-waiting-for-post-patch-window` mean stay in treatment until the named blocker clears
- `phase-grounded-ready-finish-now` means the sequential phase flow is satisfied and the live session can finish honestly
- if a saved pair times out non-grounded, `phase-insufficient-timeout` records which phase and threshold were still missing

```powershell
powershell -NoProfile -File .\scripts\guide_conservative_phase_flow.ps1 -PairRoot <pair-root> -Once
powershell -NoProfile -File .\scripts\guide_conservative_phase_flow.ps1 -UseLatest
```

## Next Grounded Conservative Cycle

Use `scripts\run_next_grounded_conservative_cycle.ps1` after the first grounded conservative capture already exists and the question is no longer "did we get the first one?" but "did this next live conservative cycle become the second grounded conservative capture, only reduce the gap, or advance the next objective?"

- it stays thin by reusing `run_human_participation_conservative_attempt.ps1` and the same mission/client/monitor/closeout stack instead of creating another evaluation engine
- because the client-assisted helper now surfaces the sequential phase-director on the auto-join path, this cycle helper inherits the same "do not leave control early and do not leave treatment before grounded patch evidence is real" policy automatically
- it writes `grounded_conservative_cycle_report.json` and `grounded_conservative_cycle_report.md` into the resulting pair root
- it records the before/after grounded conservative count, grounded-too-quiet count, strong-signal count, responsive gate, and next-live objective from the existing delta layer
- `second-grounded-conservative-capture` means the live run counted toward promotion and moved grounded conservative sessions from `1` to `2`
- `conservative-gap-reduced-but-objective-unchanged` means the live run counted and shrank the conservative gap, but the planner still points at the same next objective afterward
- `conservative-objective-advanced` means the run counted and pushed the planner to a new target such as `collect-grounded-conservative-too-quiet-evidence`
- if the run still fails, the honest next question is whether treatment-side human-present patch evidence or the post-patch observation window remained the blocker
- it differs from `run_first_grounded_conservative_attempt.ps1`: the first helper answers whether the first grounded conservative pack exists at all, while this cycle helper measures the next milestone after that first capture
- responsive still stays closed unless the existing gate logic actually changes; the cycle helper does not promote `responsive` by itself

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\run_next_grounded_conservative_cycle.ps1
```

Or with the thin wrapper:

```bat
scripts\run_next_grounded_conservative_cycle.bat
```

If the next-live objective becomes `manual-review-before-next-session`, stop spending live sessions and run the counted-pair reconciliation helper first:

```powershell
powershell -NoProfile -File .\scripts\review_counted_pair_evidence.ps1 -PairRoot .\lab\logs\eval\<pair-root>
```

That review keeps evidence precedence explicit:

- authoritative: `pair_summary.json`, lane `summary.json`, raw patch histories, mission snapshot/execution, saved control/treatment/phase gate outputs, saved live-monitor state/history, and `grounded_evidence_certificate.json`
- potentially stale narrative outputs: `mission_attainment.json`, wrapped milestone reports, older markdown summaries, and inherited explanation strings

If that review keeps the pair counted but exact treatment-side metrics still disagree across artifacts, run the metric-reconciliation helper next:

```powershell
powershell -NoProfile -File .\scripts\reconcile_pair_metrics.ps1 -PairRoot .\lab\logs\eval\<pair-root> -DryRun
```

Then execute the safe refresh only when the report says promotion state remains unchanged and the plan is limited to secondary artifacts:

```powershell
powershell -NoProfile -File .\scripts\reconcile_pair_metrics.ps1 -PairRoot .\lab\logs\eval\<pair-root> -ExecuteRefresh
```

Metric reconciliation keeps precedence explicit too:

- canonical evidence: `pair_summary.json`, lane `summary.json`, raw patch history, raw patch-apply history, telemetry history, mission snapshot/execution, and `grounded_evidence_certificate.json`
- secondary or potentially stale artifacts: `treatment_patch_window.json`, `control_to_treatment_switch.json`, `conservative_phase_flow.json`, `live_monitor_status.json`, `mission_attainment.json`, the outcome dossier, and wrapped milestone reports
- safe refresh may rebuild secondary artifacts, but it must not silently rewrite raw evidence, the append-only registry, certification thresholds, or promotion history

If the canonical metrics now agree and the only remaining contradiction is stale wrapper wording such as `human_participation_conservative_attempt.json` or `guided_session\final_session_docket.json`, run the wrapper refresh helper:

```powershell
powershell -NoProfile -File .\scripts\refresh_pair_wrapper_narratives.ps1 -PairRoot .\lab\logs\eval\<pair-root>
```

Wrapper refresh is narrower than metric reconciliation:

- reconciliation settles the canonical counts and says whether any safe derived refresh is allowed
- wrapper refresh regenerates only clearly secondary wrapper narratives from canonical sources plus the accepted reconciliation output
- counted-pair clearance is separate from registry correction: it can clear a pair-level manual-review label only when canonical evidence, refreshed wrappers, and the unchanged promotion/gate state all remain consistent
- wrapper cleanup must not silently change registry inclusion, grounded counting, responsive-gate state, or the next-live objective

If the pair-level manual-review label is cleared but the current gate or planner still looks stale, run the post-clearance recompute helper:

```powershell
powershell -NoProfile -File .\scripts\recompute_after_pair_clearance.ps1 -PairRoot .\lab\logs\eval\<pair-root>
```

This step is narrower than registry correction and broader than wrapper refresh:

- it keeps the append-only registry history untouched
- it builds an additive overlay interpretation for the cleared pair
- it recomputes downstream decision artifacts such as `registry_summary.json`, `responsive_trial_gate.json`, `next_live_plan.json`, and `next_live_session_mission.json` under the recompute output root
- it compares before vs after gate/objective/count totals so you can tell whether the stale-looking manual-review state was actually still correct

If pair-level cleanup is complete and you still need one authoritative explanation of the global manual-review state, run the grounded-evidence matrix helper:

```powershell
powershell -NoProfile -File .\scripts\review_grounded_evidence_matrix.ps1
```

Use it differently from the earlier helpers:

- counted-pair review asks whether one historically counted pair should still count
- metric reconciliation settles canonical per-pair counts and safe secondary refresh
- wrapper refresh regenerates stale wrapper narratives for one reviewed pair
- post-clearance recompute checks whether clearing that pair changes downstream decision artifacts
- grounded-evidence matrix review is global: it lists the currently counted grounded conservative sessions, shows which are appropriately conservative vs too quiet, and explains why the current responsive gate and next-live objective are or are not still justified

When the matrix shows a mixed grounded state, treat that as a real evidence pattern rather than as stale wording:

- one or more counted grounded conservative sessions say conservative looks appropriately bounded
- one or more counted grounded conservative sessions say conservative looks too quiet
- responsive should stay blocked until that mix is resolved or repeated evidence pushes the system toward one clear direction
- manual review can still be the correct answer even after pair-level cleanup if the counted grounded evidence itself is genuinely split

When that mixed state is real and the next run needs to be more discriminating instead of merely counted again, prepare the strong-signal conservative mission:

```powershell
powershell -NoProfile -File .\scripts\prepare_strong_signal_conservative_mission.ps1
```

Use it differently from the normal next-live mission:

- `prepare_next_live_session_mission.ps1` reflects the current planner and gate state as-is, even when the answer is still manual review
- `prepare_strong_signal_conservative_mission.ps1` is an explicit operator choice for the mixed-evidence case where `conservative` remains the treatment profile but the next session should exceed the grounded minimum and aim for stronger disambiguating evidence
- it raises the targets for human snapshots, human presence, treatment patch-while-human-present events, and post-patch observation window without changing the responsive gate thresholds
- it writes `strong_signal_conservative_mission.json` and `strong_signal_conservative_mission.md`, then prints the exact `run_current_live_mission.ps1`, `run_human_participation_conservative_attempt.ps1`, and `run_next_grounded_conservative_cycle.ps1` commands that can consume that mission through `-MissionPath`
- it still does not open `responsive` automatically; it only defines a stronger conservative evidence-collection goal

Use that mission when the matrix says:

- the counted grounded conservative evidence is mixed
- zero counted grounded strong-signal conservative sessions exist
- the next useful answer is "does richer conservative evidence repeat appropriately-conservative behavior or repeat too-quiet behavior?"

When you are ready to spend that live run, use the strong-signal conservative attempt wrapper:

```powershell
powershell -NoProfile -File .\scripts\run_strong_signal_conservative_attempt.ps1
```

Use it differently from the earlier generic conservative wrappers:

- it reads `strong_signal_conservative_mission.json` by default, so the stronger control/treatment human-signal, patch-window, and post-patch observation targets stay explicit for the run
- it still reuses `run_human_participation_conservative_attempt.ps1`, the local client discovery/join helpers, the sequential phase guidance, the live monitor, certification, mission attainment, outcome dossier, registry summary, responsive gate, next-live planner, and grounded-evidence matrix
- it writes `strong_signal_conservative_attempt.json` and `strong_signal_conservative_attempt.md` into the pair root so the operator can see the mission used, whether the run drifted, the before/after strong-signal counts, the before/after evidence mix, and whether the mixed state actually narrowed
- use it after the bounded join certificate is honestly `ready-for-next-strong-signal-attempt`; bounded green is the spend gate, not the same thing as a successful strong-signal capture
- `first-strong-signal-conservative-capture` means the pair both counted toward promotion and added a grounded strong-signal conservative row to the matrix; anything below that must stay explicit as non-strong-signal, still-mixed, insufficient-human-signal, interrupted-and-recovered, or manual-review-required
- a successful strong-signal conservative result means the saved pair both counted and added grounded strong-signal evidence; an unsuccessful result means the live conservative spend still failed to resolve the evidence mix honestly
- even a successful strong-signal conservative attempt does not open `responsive` automatically; it only strengthens the keep-conservative or future-responsive case depending on the saved treatment-behavior assessment

Use the verdict conservatively:

- `counted-pair-confirmed-grounded`: the pair still counts and no correction is needed
- `counted-pair-grounded-but-narrative-stale`: the pair still counts, but only safe derived artifacts should be refreshed
- `counted-pair-needs-manual-review-label`: the pair still counts, but it should keep an explicit manual-review label because authoritative artifacts disagree
- `counted-pair-needs-registry-correction`: authoritative evidence no longer supports the counted state, so the registry/planner need an explicit correction path
- `counted-pair-non-grounded`: the pair should not be treated as promotion-counting evidence

The helper writes `counted_pair_review.json` and `counted_pair_review.md` into the pair root by default. It may safely rebuild downstream dossier-style artifacts when the pair remains counted, but it must not fabricate evidence or silently rewrite promotion history.

## Local Client Discovery And Lane Join

Use `scripts\discover_hldm_client.ps1` before a real grounded conservative attempt when you need an explicit answer to "can this machine launch `hl.exe` into the live lane right now?"

- it checks `-ClientExePath` first, then `HL_CLIENT_EXE`, then standard Steam roots, Steam library folders, registry Steam hints, and finally the legacy local Half-Life paths already mentioned in this repo
- it writes `local_client_discovery.json` and `local_client_discovery.md`
- `client-not-found` means automatic local launch is unavailable here, not that the servers are broken
- `ready-with-warnings` in preflight now explicitly covers the case where the servers are ready but `hl.exe` was not found and the operator must join manually

Run it like this:

```powershell
powershell -NoProfile -File .\scripts\discover_hldm_client.ps1
```

Use `scripts\join_live_pair_lane.ps1` when you want the local client to join one live lane cleanly without hand-copying the port:

- `-PairRoot` or `-UseLatest` lets the helper read the pair pack and pick the correct control or treatment target
- `-Port` and `-Map` keep the helper usable before a pair root exists
- `-DryRun` prints the resolved lane target, the client-discovery result, and the exact launch command without starting the client

Examples:

```powershell
powershell -NoProfile -File .\scripts\join_live_pair_lane.ps1 -Lane Control -UseLatest -DryRun
powershell -NoProfile -File .\scripts\join_live_pair_lane.ps1 -Lane Treatment -PairRoot D:\DEV\CPP\HL-Bots\lab\logs\eval\fgca40-live\20260420-212515-crossfire-b4-s3-cp27016-tp27017 -DryRun
```

The pair runner now writes the helper commands directly into `control_join_instructions.txt`, `treatment_join_instructions.txt`, and `pair_join_instructions.txt`, so the operator can either launch the client automatically or fall back to the printed `connect` commands manually.

If `hl.exe` launched but the saved pair still shows `0` human snapshots / `0` human presence seconds, run the client-presence audit before another live spend:

```powershell
powershell -NoProfile -File .\scripts\audit_client_presence.ps1 -PairRoot .\lab\logs\eval\<pair-root>
```

Use that audit differently from certification or the scorecard:

- it is a diagnosis helper, not a promotion helper
- it classifies the chain conservatively as launch, server-connect, lane-attribution, human-snapshot accumulation, and final pair-summary reflection
- `client-launched-but-no-server-connect` means `hl.exe` started but no server log ever captured a real connection
- `client-connected-but-no-lane-attribution` means a connection exists but the saved pair artifacts do not tie it to a lane cleanly
- `lane-attribution-present-but-no-human-snapshots` means the pair already preserved lane-local connection evidence, but telemetry and summaries never counted a human player
- if the audit stays `inconclusive-manual-review`, the logs are too weak to name a narrower break point honestly

When the audit narrows the problem to the join-completion boundary, run the bounded control-lane probe before another full live conservative session:

```powershell
powershell -NoProfile -File .\scripts\run_client_join_completion_probe.ps1
```

Use that probe differently from the broader audit:

- it is a bounded reproduction, not a pair-session scorecard or certification path
- it reuses the existing no-AI control lane, local client discovery, and lane-join helper instead of inventing a new launcher
- it records the exact completion chain stage-by-stage: `client-discovered`, `launch-command-prepared`, `client-process-launched`, `server-connection-seen`, `entered-the-game-seen`, `first-human-snapshot-seen`, `human-presence-accumulating`, and `control-lane-human-usable`
- `connected-but-not-entered-game` means the server saw the socket connect, but there is still no trusted in-game join state
- `entered-game-but-no-human-snapshot` means the join completed far enough to enter the game, but saved telemetry still never counted a human player
- `human-snapshot-seen-but-presence-does-not-accumulate` means the first snapshot appeared, but saved human-presence time still failed to build into usable evidence
- the system is ready to spend another full strong-signal conservative session only after the probe shows `entered-the-game-seen` or equivalent, at least one counted human snapshot, and human presence beginning to accumulate in saved control-lane evidence
- this probe comes before another full evidence-collection run because it isolates join completion without wasting a treatment lane or a full strong-signal mission on a launch-path problem

When one bounded probe succeeds but reliability still looks mixed, run the repeated join reliability matrix before another full strong-signal conservative session:

```powershell
powershell -NoProfile -File .\scripts\run_client_join_reliability_matrix.ps1 -Attempts 3 -UseLatestMissionContext
```

Use that matrix differently from the one-off probe:

- it reuses `run_client_join_completion_probe.ps1` in a bounded loop instead of inventing a new launcher
- it writes `client_join_reliability_matrix.json` / `.md` plus `client_join_reliability_certificate.json` / `.md`
- `not-ready-repeat-join-hardening` means repeated bounded probes still failed before saved human presence began accumulating, so another full strong-signal conservative session would still be premature
- `partially-reliable-repeat-bounded-probes` means the repaired path sometimes reaches entered-the-game, first human snapshot, and accumulating saved human presence, but the repeated suite still contains earlier-chain failures or budget overruns
- `ready-for-next-strong-signal-attempt` is intentionally strict: the current helper only certifies ready after every repeated bounded attempt reaches entered-the-game, first human snapshot, accumulating saved human presence, and control-lane human-usable without overrunning the matrix budget
- this helper differs from `audit_client_presence.ps1`: the audit diagnoses one failed pair or probe, while the reliability matrix asks whether the repaired join path is stable enough to justify another full strong-signal conservative spend

If the repeated suite still fails before join is even attempted, audit the failed probe root directly:

```powershell
powershell -NoProfile -File .\scripts\audit_probe_lane_startup.ps1 -ProbeRoot .\lab\logs\eval\join_reliability_matrices\<matrix-root>\att\<attempt>\<probe-root>
```

Use that startup audit differently from the later join-completion audit:

- it is only about probe-lane startup and materialization, not later human-signal quality
- `lane root materialized` means the bounded control lane actually created its lane capture root and lane metadata under the probe output root
- `port ready` means the bounded control lane reached a real listener on the target port before the join helper gate
- `lane-launch-attempted-no-root` means startup died before the lane root existed; a saved `Resolve-Path` missing-directory error plus a very long expected path is strong evidence of path-depth failure
- `lane-root-created-no-port-ready` means the lane root exists, but the bounded control lane still never reached a ready listener
- `port-ready-no-join-invocation` means startup cleared the lane-root and port-ready gates, but the join helper still was not called
- only move back to a full strong-signal conservative session after the repeated bounded suite consistently clears startup/materialization and the remaining break, if any, is later in the join or telemetry chain

When startup is already healthy but repeated probes still do not reliably cross from `connected` into `entered the game`, compare one successful bounded probe against the failed repeated probes directly:

```powershell
powershell -NoProfile -File .\scripts\audit_entered_game_boundary.ps1 -UseLatest
```

Use that entered-the-game audit differently from the broader client-presence audit:

- it compares one successful bounded probe against failed repeated probes instead of re-auditing the whole pair workflow
- it checks launch-command equivalence, working-directory equivalence, lane-ready timing, client-PID lifetime evidence, and the first server-side `connected` / `entered the game` timestamps
- `connected-but-never-entered-game` means at least one failed repeated probe now reaches server connect, but admission still stops before the player is fully in game
- `entered-game-racy` means the same launch path already succeeded once and the lane is ready before launch, but repeated probes still fail inconsistently, so the narrowest divergence is timing/admission reliability rather than static configuration
- only return to a full strong-signal conservative session after the repeated matrix shows the entered-the-game boundary is stable across the bounded suite, not just on one lucky probe

When the server already shows `entered the game`, but the first saved human snapshot still appears missing, run the narrower first-human-snapshot boundary audit against the probe root:

```powershell
powershell -NoProfile -File .\scripts\audit_first_human_snapshot_boundary.ps1 -ProbeRoot .\lab\logs\eval\join_reliability_matrices\<matrix-root>\att\<attempt>\<probe-root>
```

Use that boundary audit differently from the broader client-presence audit:

- it compares authoritative HLDS `connected` / `entered the game` lines plus saved telemetry history against the secondary lane summary and session-pack artifacts
- `snapshot-written-but-summary-not-updated` means the first human snapshot already exists in `telemetry_history.ndjson`, but the saved lane summary/session layer still failed to reflect it
- `first-human-snapshot-seen` means the lane summary now reflects the first counted human snapshot, even if accumulated saved presence is still thin

When one or more bounded probes already succeed end to end, but a full strong-signal conservative session still reports `control-baseline-no-humans` and `ai-healthy-no-humans`, compare the two paths directly:

```powershell
powershell -NoProfile -File .\scripts\audit_bounded_vs_full_session_divergence.ps1
```

Use that divergence audit differently from the broader client-presence audit and the narrower entered-the-game audit:

- it compares a successful bounded probe root against a failed full-session pair root, not just probe-vs-probe or launch-to-snapshot evidence in isolation
- it lines up launch command, working directory, pair/lane roots, control/treatment join attempts, control/treatment phase-gate outputs, and the timestamps for launch, connect, entered-the-game, first human snapshot, and accumulating human presence
- `bounded-success-full-control-never-cleared` means the bounded path already proved the local join chain can work, but the full session still died earlier and never cleared the control-first gate
- `bounded-success-full-treatment-never-joined` means the full control side survived far enough to stay in sequence, but treatment progression still diverged and never got a real human-participation chance
- `bounded-success-full-summary-ingestion-missing` means the full session reached the same admission boundary as the bounded probe, but pair/lane summary reflection still diverged later
- spend another full strong-signal conservative session only after the divergence audit shows the full-session path is back in line with the already-working bounded join path; otherwise stay on bounded diagnosis and repair
- `human-presence-accumulating` means the later summary layer is no longer the blocker and saved human-presence time is actually building
- this helper differs from `audit_client_presence.ps1`: the broader audit finds the chain stage, while the first-human-snapshot audit isolates whether the break is enumeration, human classification, persisted telemetry, or summary aggregation

When the full-session join path already works but the latest strong-signal session still stopped short in control, prove the control-only accumulation gate before spending treatment again:

```powershell
powershell -NoProfile -File .\scripts\run_control_phase_accumulation_probe.ps1
```

- this helper is narrower than a full strong-signal session: it reuses the strong-signal mission, local client discovery, join helper, control-first gate, and existing closeout stack, but keeps the human in the no-AI control lane only
- `control-phase-strong-signal-target-met` means the control-only run really did clear the stronger control target, so the next full strong-signal conservative control+treatment attempt is justified
- `control-phase-human-usable-but-below-strong-signal-target` means the control lane produced real human-usable evidence, but still stayed below the stronger `5` snapshots / `90` seconds bar
- `control-phase-insufficient-human-signal` means the control-only proof still failed earlier, so another full control+treatment spend would still be premature
- this helper differs from the broader client-presence and bounded-vs-full divergence audits because it is no longer asking whether the client can join at all; it is asking whether the full control-first workflow can hold enough real control-lane human signal to unlock the next full strong-signal spend honestly

When the control-only proof already succeeds but a full strong-signal conservative rerun still fails during control-to-treatment handoff or final closeout, audit the later full-session chain directly:

```powershell
powershell -NoProfile -File .\scripts\audit_full_session_handoff.ps1
```

- this helper is later and narrower than `audit_bounded_vs_full_session_divergence.ps1`: it assumes the full session already proved control readiness and isolates what happened next between `control-ready`, treatment join invocation, treatment phase start, and final closeout
- it reads `control_to_treatment_switch.json`, `conservative_phase_flow.json`, `treatment_patch_window.json`, `live_monitor_status.json`, `guided_session\mission_execution.json`, `guided_session\session_state.json`, `guided_session\final_session_docket.json` when present, pair/lane summaries, and the nearest human-participation runner stdout/stderr
- `control-ready-not-observed-by-runner` means authoritative switch artifacts cleared control, but the full wrapper never persisted the same handoff observation
- `control-ready-observed-but-treatment-join-not-invoked` means the full chain advanced out of control but no trustworthy local treatment join request or launch was captured
- `treatment-phase-started-but-closeout-raced` means treatment-stage waiting began, but the session still exited without a trustworthy final pair pack
- `closeout-raced-before-final-artifacts` means the pair root exists, but `pair_summary.json` and the final docket were truncated before the closeout stack finished
- spend another full strong-signal conservative session only after the handoff audit is `handoff-chain-complete` or after one narrow repair plus one justified rerun proves treatment phase start and final artifact production without racing

When the latest repaired full rerun already counts as grounded evidence but still fails to capture treatment-side strong-signal evidence, audit that gap directly before another live spend:

```powershell
powershell -NoProfile -File .\scripts\audit_treatment_strong_signal_gap.ps1 -UseLatest -DryRun
```

- this helper is narrower than the broader grounded-evidence matrix review because it assumes the pair already counts and asks only why treatment-side strong-signal still did not capture
- it also differs from `reconcile_pair_metrics.ps1`: that helper is for general canonical metric reconciliation on a counted pair, while this one applies a treatment-side strong-signal precedence order to say whether the remaining gap is real or just wrapper drift
- canonical sources are `pair_summary.json`, treatment `summary.json`, `grounded_evidence_certificate.json`, patch history, patch-apply history, telemetry history, and human-presence timing
- secondary sources are `treatment_patch_window.json`, `conservative_phase_flow.json`, `live_monitor_status.json`, `mission_attainment.json`, `strong_signal_conservative_attempt.json`, and other wrapper narratives
- `strong-signal-gap-real-treatment-still-short` means the canonical treatment evidence is still below the mission target, so another full conservative session must still capture the missing human-present patch event or whatever exact metric remains short
- `patch-event-under-count-in-derived-layer`, `post-patch-window-under-count-in-derived-layer`, or `strong-signal-criteria-met-but-wrapper-stale` mean refresh-only branches; use `-DryRun` first and `-ExecuteRefresh` only when the helper says the secondary refresh is safe and promotion state remains unchanged

When the later treatment completion run regresses from a better `5 / 100` treatment window down to a shorter `4 / 80` treatment window, compare those two pair roots directly before another live spend:

```powershell
powershell -NoProfile -File .\scripts\audit_treatment_dwell_and_patch_consistency.ps1
powershell -NoProfile -File .\scripts\audit_treatment_dwell_and_patch_consistency.ps1 -BetterPairRoot .\lab\logs\eval\ssca53-live\<better-pair> -RegressedPairRoot .\lab\logs\eval\ssca53-live\<regressed-pair>
```

- this helper is narrower than `audit_treatment_strong_signal_gap.ps1`: the earlier audit asks whether the latest grounded rerun truly stayed short of strong-signal, while this one asks why a later treatment run became shorter and whether the remaining mismatch is real dwell loss, an early treatment cutoff, or only secondary artifact drift
- canonical sources stay the same: treatment `summary.json`, `pair_summary.json`, `grounded_evidence_certificate.json`, patch history, patch-apply history, telemetry history, and the saved human-presence timeline
- secondary sources stay explicitly secondary: `treatment_patch_window.json`, `conservative_phase_flow.json`, `live_monitor_status.json`, `mission_attainment.json`, and wrapper narratives such as `human_participation_conservative_attempt.json` and `strong_signal_conservative_attempt.json`
- `real-treatment-dwell-regression` means the later run really lost treatment time before the next human sample could land, so refresh-only cleanup is not enough and the next step remains treatment-hold hardening
- `derived-layer-patch-undercount-only` means canonical treatment evidence stayed stable and only the secondary layer needs a safe refresh
- use refresh-only cleanup only when the helper says the disagreement is confined to secondary artifacts; otherwise explain the dwell loss first and delay another live spend

When that audit already proves the remaining blocker is one missing treatment patch-while-humans-present event, spend the next conservative run through the dedicated completion helper:

```powershell
powershell -NoProfile -File .\scripts\run_treatment_patch_completion_attempt.ps1
```

- this helper is narrower than the earlier generic strong-signal conservative attempt wrapper: it still reuses the same strong-signal mission, mission-driven runner, client-assisted join path, sequential control/treatment guidance, live monitor, certification, outcome dossier, grounded-evidence matrix, responsive gate, and next-live planner, but its report is centered on the missing treatment patch target
- it records the canonical treatment patch count before and after the run, says explicitly whether the third human-present patch was captured, and reports whether treatment became strong-signal-ready
- `treatment-patch-target-met` means the missing third human-present patch was finally captured and the run changed the strong-signal evidence state for real
- `treatment-patch-target-still-short` means the run stayed honest, but treatment still ended below the patch-event target
- `treatment-phase-insufficient-human-signal` means the run did not preserve enough treatment-side human presence to answer the patch-completion question honestly
- `treatment-phase-manual-review-required` means the third patch may have been captured, but the final strong-signal result still needs explicit review before it can be treated as a clean first capture
- `responsive` still stays closed unless the saved evidence actually changes

When the latest regressed full rerun looks one human sample short, audit that cutoff directly before another live spend:

```powershell
powershell -NoProfile -File .\scripts\audit_treatment_closeout_cutoff.ps1
powershell -NoProfile -File .\scripts\audit_treatment_closeout_cutoff.ps1 -PairRoot .\lab\logs\eval\ssca53-live\<regressed-pair>
```

- this helper is narrower than `audit_treatment_dwell_and_patch_consistency.ps1`: the dwell audit explains why one run regressed against another, while this one asks whether the later run actually finalized treatment before the next expected human sample could land
- `next expected human sample` means the next treatment-side human snapshot implied by the saved 20-second human-presence cadence in the lane timeline
- `closeout-started-before-next-expected-human-sample` means the run started finalizing while treatment was still below target and the next sample was due soon enough that one bounded hold could plausibly change the dwell result
- `closeout-started-while-safe_to_leave_false` means treatment still was not safe to leave, but the saved timing is not tight enough to prove a one-sample cutoff
- the closeout guard is bounded on purpose: it only holds treatment open for one short grace window so the next expected sample can arrive, then it recomputes instead of silently loosening thresholds or leaving the lane open indefinitely
- if a guarded rerun fixes treatment dwell but the third patch event is still missing, treat that as progress but not success; another conservative session is justified only if the remaining live gap is still exactly the missing patch event rather than another dwell cutoff

If the post-guard full rerun fails earlier and never produces `pair_summary.json`, audit that artifact gap before spending another live session:

```powershell
powershell -NoProfile -File .\scripts\audit_full_rerun_artifact_gap.ps1
powershell -NoProfile -File .\scripts\audit_full_rerun_artifact_gap.ps1 -PairRoot .\lab\logs\eval\ssca53-live\<failed-rerun-pair>
```

- this helper is narrower than the treatment closeout-cutoff audit: the cutoff audit assumes treatment already became evaluable, while this one asks why the validating full rerun failed before a trustworthy final pair pack existed at all
- it distinguishes whether the rerun failed before control-ready, before treatment request, during lane materialization, or during final summary flush and closeout
- `pair-summary-missing-but-recoverable` means the lane summaries survived and the existing salvage path may still rebuild pair-level closeout safely
- `process-exit-before-summary-flush` means the pair runner died before the raw lane summary or pair summary could be written, so downstream certificate and mission-attainment helpers had nothing authoritative to consume
- use the salvage decision in `full_rerun_artifact_gap_audit.json` to decide whether to attempt pair-local salvage or spend a new full rerun

When you want the whole first grounded conservative attempt plus automatic local joins, prefer:

```powershell
powershell -NoProfile -File .\scripts\run_human_participation_conservative_attempt.ps1
```

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
- Pair-session registry summaries and planning artifacts: `lab/logs/eval/registry/registry_summary.json`, `registry_summary.md`, `profile_recommendation.json`, `profile_recommendation.md`, `responsive_trial_gate.json`, `responsive_trial_plan.json`, `next_live_plan.json`, `next_live_plan.md`, `next_live_session_mission.json`, and `next_live_session_mission.md`
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
- `scripts/run_current_live_mission.ps1`: mission-driven wrapper that launches the current mission, records drift, and writes `mission_execution.json` / `.md` before the post-run closeout reuses that launch record.
- `scripts/run_current_live_mission.bat`: `cmd.exe` wrapper for the mission-driven runner.
- `scripts/assess_latest_session_recovery.ps1`: interruption/recovery classifier that inspects the latest pair pack or an explicit pair root and writes `session_recovery_report.json` plus `session_recovery_report.md`.
- `scripts/assess_latest_session_recovery.bat`: `cmd.exe` wrapper for the recovery-assessment helper.
- `scripts/finalize_interrupted_session.ps1`: conservative salvage helper that reads the recovery report, reruns only the honest closeout steps for recoverable sessions, and writes `session_salvage_report.json` plus `session_salvage_report.md`.
- `scripts/finalize_interrupted_session.bat`: `cmd.exe` wrapper for the interrupted-session salvage helper.
- `scripts/continue_current_live_mission.ps1`: top-level continuation controller that inspects the latest or explicit pair root, chooses no-action, review-only, salvage, rerun, or manual review, and writes `mission_continuation_decision.json` plus `mission_continuation_decision.md`.
- `scripts/continue_current_live_mission.bat`: `cmd.exe` wrapper for the continuation controller.
- `scripts/build_latest_session_outcome_dossier.ps1`: consolidates the latest pair's scorecard, shadow review, grounded certification, before-vs-after delta, current gate, and current next-live plan into `session_outcome_dossier.json` plus `session_outcome_dossier.md`.
- `scripts/build_latest_session_outcome_dossier.bat`: `cmd.exe` wrapper for the outcome-dossier helper.
- `scripts/plan_next_live_session.ps1`: computes the certified-grounded promotion gap, emits `next_live_plan.json` plus `next_live_plan.md`, and recommends the next live profile and session objective.
- `scripts/plan_next_live_session.bat`: `cmd.exe` wrapper for the next-live session planner.
- `scripts/prepare_next_live_session_mission.ps1`: turns the current gate, planner, and latest outcome context into `next_live_session_mission.json` plus `next_live_session_mission.md` for the very next live run.
- `scripts/prepare_next_live_session_mission.bat`: `cmd.exe` wrapper for the mission-brief helper.
- `scripts/prepare_strong_signal_conservative_mission.ps1`: writes `strong_signal_conservative_mission.json` plus `strong_signal_conservative_mission.md` when the next useful conservative run needs stronger-signal disambiguation rather than another generic grounded session.
- `scripts/prepare_strong_signal_conservative_mission.bat`: `cmd.exe` wrapper for the strong-signal conservative mission helper.
- `scripts/run_client_join_reliability_matrix.ps1`: bounded repeated control-lane probe harness that aggregates per-attempt join-chain outcomes into a reliability matrix and readiness certificate before another full strong-signal conservative run is spent.
- `scripts/run_client_join_reliability_matrix.bat`: `cmd.exe` wrapper for the join reliability matrix helper.
- `scripts/audit_probe_lane_startup.ps1`: bounded probe-lane startup/materialization audit that explains whether a failed repeated probe died before lane-root creation, before port-ready, or before join invocation.
- `scripts/audit_probe_lane_startup.bat`: `cmd.exe` wrapper for the probe-lane startup audit helper.
- `scripts/audit_first_human_snapshot_boundary.ps1`: later ingestion-boundary audit that compares authoritative server entry plus telemetry-history evidence against saved lane summary/session artifacts when the first human snapshot still appears missing.
- `scripts/audit_first_human_snapshot_boundary.bat`: `cmd.exe` wrapper for the first-human-snapshot boundary audit helper.
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
