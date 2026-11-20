# Run a Frappe CLI command natively (spike): .\run-frappe.ps1 <log name> <args...>
param([string]$Log, [Parameter(ValueFromRemainingArguments)][string[]]$FrappeArgs)
$S = 'C:\srv\portfolio\erp\native-spike'
$env:FRAPPE_BACKGROUND_WORKERS_NOFORK = '1'
$env:PYTHONUTF8 = '1'          # Frappe opens text files without an encoding; Windows would use cp1252
$env:PATH = "$S\mariadb\bin;$S\tools;C:\Program Files\Git\bin;$env:PATH"   # mariadb CLI + bash (frappe.utils.execute_in_shell)
$argv = @("$S\frappe_win.py", 'frappe') + $FrappeArgs
$t = Get-Date
$p = Start-Process "$S\env\Scripts\python.exe" -ArgumentList $argv -WorkingDirectory "$S\bench\sites" -NoNewWindow -PassThru `
    -RedirectStandardOutput "$S\$Log.out.log" -RedirectStandardError "$S\$Log.err.log"
try { $p.PriorityClass = 'BelowNormal' } catch {}
$p.WaitForExit()
"exit $($p.ExitCode) after $([int]((Get-Date) - $t).TotalSeconds) s"
