# Blocker Classification

exact_blocker_classification: `required_elevated_high_integrity_shell_not_provided_for_p18r53`

Primary blocker:
- The live shell is not genuinely elevated/high-integrity.
- Mandatory integrity label is `Medium`, not `High` or `System`.
- `BUILTIN\Administrators` is `Group used for deny only`.
- `CheckTokenMembership(Admin SID)` is `false`.
- `WindowsPrincipal.IsInRole(Administrator)` is `false`.
- `IsUserAnAdmin()` is `false`.
- `cmd /c fltmc` failed with `Access is denied`.

Secondary environment drift recorded:
- The live working copy identifies as `hl-bots-ai`, not the CSClient repository named in the prompt.
- The expected `artifacts\test-runs` tree is absent before this run.
- The full P18R52 prompt-local bundle is absent before this run.
- `docs\tests\smoke.md` is absent.
- `run_csclient_smoke.ps1` is absent.
- `tools\compare_post_voicemask_window.ps1` is absent.
- `stage_csclient_regamedll_rehlds_verify.ps1` is absent.
- `run_csclient_regamedll_rehlds_verify_manual_dedicated.bat` is absent.

Fail-closed result:
- Direct bounded logman preflight was not attempted.
- No traced rerun was allowed.
- No traced PID exists for this run.
- No fresh raw fallback artifact exists for this run.
- No comparator run was allowed.
- No code-side remediation is justified.
