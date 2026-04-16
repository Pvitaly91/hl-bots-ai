# Privilege Context

Fresh shell proof for P18R53:
- `mandatory_integrity_label = Medium Mandatory Level`
- `BUILTIN\Administrators = deny-only`
- `CheckTokenMembership(Admin SID) = false`
- `WindowsPrincipal.IsInRole(Administrator) = false`
- `IsUserAnAdmin() = false`
- `cmd /c fltmc = Access is denied`

Process identity:
- `process_path = C:\Program Files\PowerShell\7\pwsh.exe`
- `pid = 12460`
- `session_id = 3`
- `working_directory = D:\DEV\CPP\HL-Bots`

Gate decision:
- `shell_genuinely_elevated = false`
- `automation_elevation_attempted = false`
- `direct_preflight_allowed = false`
