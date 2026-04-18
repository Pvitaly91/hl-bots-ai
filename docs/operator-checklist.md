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
7. Run `scripts\review_latest_pair_run.ps1`.
8. Run `scripts\run_shadow_profile_review.ps1 -UseLatest -Profiles conservative default responsive`.
9. Run `scripts\score_latest_pair_session.ps1`.
10. Run `scripts\register_pair_session_result.ps1`.
11. Run `scripts\summarize_pair_session_registry.ps1`.
12. Use the scorecard, shadow recommendation, and registry recommendation together before choosing the next live profile.

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

1. `scorecard.md`
2. `pair_summary.md`
3. `comparison.md`
4. treatment `summary.md` or `session_pack.md` if the treatment lane looks too quiet
5. control `summary.md` if the control lane looks weak or sparse

The fastest way to review the newest pair is:

```powershell
powershell -NoProfile -File .\scripts\review_latest_pair_run.ps1
```

Then score it with:

```powershell
powershell -NoProfile -File .\scripts\score_latest_pair_session.ps1
```

Run the shadow review against the latest pair pack before you decide whether `responsive` is worth a real follow-up session:

```powershell
powershell -NoProfile -File .\scripts\run_shadow_profile_review.ps1 -UseLatest -Profiles conservative default responsive
```

Or target a specific saved pair pack:

```powershell
powershell -NoProfile -File .\scripts\run_shadow_profile_review.ps1 -PairRoot .\lab\logs\eval\pairs\<pair-pack> -RequireHumanSignal -MinHumanSnapshots 2 -MinHumanPresenceSeconds 40
```

Then register it into the ledger:

```powershell
powershell -NoProfile -File .\scripts\register_pair_session_result.ps1
```

Then summarize the accumulated registry:

```powershell
powershell -NoProfile -File .\scripts\summarize_pair_session_registry.ps1
```

## If No Humans Join

- keep the run only as plumbing validation
- do not claim tuning evidence
- rerun later with a real participant and keep the same conservative treatment profile first

## If Treatment Never Patches While Humans Are Present

- inspect `comparison.md` and the treatment lane `summary.md`
- confirm whether humans were present long enough for treatment to react
- if the pair still says treatment stayed too quiet relative to control, only then consider a later follow-up with `responsive`

## How To Interpret The Scorecard

- `too quiet`: humans were present long enough to compare lanes, but conservative still stayed quieter than control without grounded human-present patch evidence
- `appropriately conservative`: conservative produced grounded human-present patch evidence and did not look oscillatory or overactive
- `inconclusive`: human presence, patch timing, or post-patch windows were still too weak to justify a profile decision
- `too reactive`: the treatment lane looked oscillatory or violated a guardrail and needs manual review before another live profile choice

## How To Use The Recommendation

- `keep-conservative-and-collect-more`: conservative stays the next live default
- `treatment-evidence-promising-repeat-conservative`: repeat conservative before changing profile
- `weak-signal-repeat-session`: collect another conservative session because the live evidence stayed weak
- `conservative-looks-too-quiet-try-responsive-next`: responsive is justified as the next candidate only because conservative stayed too quiet under usable human presence
- `insufficient-data-repeat-session`: reject the session as tuning evidence and repeat the live pair first
- `review-artifacts-manually`: inspect `comparison.md`, `scorecard.md`, and the treatment lane summary before choosing the next action

## How To Read Shadow Review

- `keep-conservative`: the captured lane does not justify a live profile change yet.
- `conservative-and-default-similar`: shadow `default` behaved materially like the captured conservative lane, so switching profiles would spend human time without new grounded evidence.
- `insufficient-data-no-promotion`: the captured lane never cleared the human-signal gate strongly enough for promotion. Shadow replay should not be used to justify `responsive`.
- `conservative-looks-too-quiet-responsive-candidate`: conservative looks too quiet and responsive would have created more grounded human-present treatment evidence without tripping the guardrails. Treat this as a candidate only, not proof.
- `responsive-would-have-overreacted`: responsive looked too reactive in counterfactual replay, so conservative should remain live.
- shadow review is useful before spending a real live session on `responsive` because it gives the operator a bounded "what if" answer from the same captured telemetry instead of a blind promotion.

## Cross-Session Ledger

- `scripts\register_pair_session_result.ps1` appends the reviewed and scored pair pack into `lab\logs\eval\registry\pair_sessions.ndjson`
- registration defaults to the newest pair pack and skips duplicate pair packs by default
- optional notes can be linked with `-NotesPath` or by placing a notes file in the pair root; missing notes never fail the registration step
- `scripts\summarize_pair_session_registry.ps1` writes `registry_summary.json`, `registry_summary.md`, `profile_recommendation.json`, and `profile_recommendation.md`
- the registry summary tells you how many sessions are still insufficient-data or weak-signal, how many are tuning-usable or strong-signal, how often treatment patched while humans were present, how often shadow review suggested keep conservative, insufficient-data-no-promotion, responsive-candidate, or responsive-too-reactive, and how each treatment profile is behaving across runs
- conservative remains the default next live profile until the registry shows repeated grounded evidence that responsive is justified
- responsive should be rejected or reverted when grounded responsive evidence looks too reactive

## Optional Session Notes

- `docs\first-live-pair-notes-template.md` is a lightweight place to jot down who joined, how long they stayed, and whether treatment felt too quiet or too reactive

## Preflight Verdict Meanings

- `ready-for-human-pair-session`: required scripts, build output, ports, and profile selection are ready without current warnings
- `ready-with-warnings`: the pair can be run, but at least one non-blocking prerequisite or optional helper needs attention
- `blocked`: do not spend a human session yet; fix the reported blockers first
