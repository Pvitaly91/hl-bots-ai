# First Real Human Pair-Session Checklist

Use this checklist before spending a real human session on the control-vs-treatment workflow.

## Prerequisites

- Windows lab machine with `hl-bots-ai.sln` building as `Release|Win32`
- `scripts\preflight_real_pair_session.ps1` reports either `ready-for-human-pair-session` or `ready-with-warnings`
- HLDS lab paths resolve under `lab\`
- `scripts\run_control_treatment_pair.ps1` is available
- default treatment profile remains `conservative`

## Default Pair Workflow

Run this first:

```powershell
powershell -NoProfile -File .\scripts\preflight_real_pair_session.ps1
```

Then start the live pair:

```powershell
powershell -NoProfile -File .\scripts\run_control_treatment_pair.ps1 -Map crossfire -BotCount 4 -BotSkill 3 -ControlPort 27016 -TreatmentPort 27017 -DurationSeconds 80 -WaitForHumanJoin -HumanJoinGraceSeconds 120 -TreatmentProfile conservative -SkipSteamCmdUpdate -SkipMetamodDownload
```

Default ports and lanes:

- control lane: `127.0.0.1:27016`
- treatment lane: `127.0.0.1:27017`
- control lane role: no-AI baseline with `jk_ai_balance_enabled 0` and no sidecar
- treatment lane role: AI treatment with the `conservative` profile

## Why Conservative Is The Default

- it demands more human signal before claiming the lane is useful
- it reacts more slowly near the boundary, which is safer for the first real human session
- it is the cleanest way to learn whether the treatment lane is too quiet before considering `responsive`

## Operator Sequence

1. Run preflight and stop only if the verdict is `blocked`.
2. Start the paired workflow.
3. Join the control lane first.
4. Stay in the control lane for about the configured `-MinHumanPresenceSeconds` window. Treat roughly 60 seconds or more as the minimum useful target when using the current live defaults.
5. Let the runner advance to the treatment lane, then join the treatment lane second.
6. Stay in the treatment lane for about the same minimum useful window.
7. After the run, inspect the pair pack before making any tuning claims.

## What Counts As Insufficient Data

- no humans join either lane
- a human joins only briefly and does not stay long enough to satisfy the minimum human-presence window
- treatment never patches while humans are present
- there is no meaningful post-patch observation window after a treatment patch

These runs are at most `plumbing-valid only` or `partially usable`.

## What Counts As Usable Signal

- a human stays in both lanes long enough to satisfy the minimum human-presence gate
- control and treatment both remain launch-healthy
- treatment patches while humans are present
- there is enough time after a human-present patch to observe whether the treatment changed the live lane

This is the minimum bar for `tuning-usable`. Multiple grounded post-patch windows are what move a pair toward `strong-signal`.

## Files To Inspect After The Run

Open these in order:

1. `pair_summary.md`
2. `comparison.md`
3. treatment `summary.md` or `session_pack.md` if the treatment lane looks too quiet
4. control `summary.md` if the control lane looks weak or sparse

The fastest way to review the newest pair is:

```powershell
powershell -NoProfile -File .\scripts\review_latest_pair_run.ps1
```

## If No Humans Join

- keep the run only as plumbing validation
- do not claim tuning evidence
- rerun later with a real participant and keep the same conservative treatment profile first

## If Treatment Never Patches While Humans Are Present

- inspect `comparison.md` and the treatment lane `summary.md`
- confirm whether humans were present long enough for treatment to react
- if the pair still says treatment stayed too quiet relative to control, only then consider a later follow-up with `responsive`

## Preflight Verdict Meanings

- `ready-for-human-pair-session`: required scripts, build output, ports, and profile selection are ready without current warnings
- `ready-with-warnings`: the pair can be run, but at least one non-blocking prerequisite or optional helper needs attention
- `blocked`: do not spend a human session yet; fix the reported blockers first
