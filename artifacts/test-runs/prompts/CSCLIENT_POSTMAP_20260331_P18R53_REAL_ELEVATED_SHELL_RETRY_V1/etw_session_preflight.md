# ETW Session Preflight

Direct ETW preflight status: `forbidden by shell gate`

Gating decision:
- `shell_genuinely_elevated = false`
- `automation_elevation_attempted = false`
- `direct_preflight_attempted = false`
- `blocker = required_elevated_high_integrity_shell_not_provided_for_p18r53`

Unchanged bounded configuration retained for reference only:
- providers:
  - `Microsoft-Windows-Kernel-Process:0x10:4`
  - `Microsoft-Windows-Kernel-File:0x1EF0:4`
- filename family: `*buffer*.dat`
- filesystem root: `D:\Steam\steamapps\common\Half-Life`
- scope: `fallback PID only`
- comparator window core: `0x1F29-0x1FF9`
- comparator window extension: `0x1FFA-0x2009`
- session naming family: `csclient-p18r53-preflight-<pid>-<timestamp>`

Because no real high-integrity shell was available:
- `actual_session_name = none`
- `provider_file_path = none`
- `etl_output_path = none`
- `exact logman command = none`
