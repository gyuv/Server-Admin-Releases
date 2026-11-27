<#
  Server Admin Suite - File activity repair
  Run on the affected server in PowerShell as Administrator:
    powershell -ExecutionPolicy Bypass -File .\Fix-FileActivity.ps1
  It checks every link in the chain, repairs what is wrong, makes a test change and confirms it is recorded.
  A report is saved to C:\ProgramData\ServerAdminSuite\fileactivity-repair.txt
#>
$ErrorActionPreference = 'Continue'
$data = Join-Path $env:ProgramData 'ServerAdminSuite'
$cfgPath = Join-Path $data 'config.json'
$report = New-Object System.Collections.Generic.List[string]
function Say($ok, $text) { $line = ('[{0}] {1}' -f $(if ($ok -eq $true) { ' OK ' } elseif ($ok -eq $false) { 'FIX ' } else { 'INFO' }), $text); $report.Add($line); Write-Host $line -ForegroundColor $(if ($ok -eq $true) { 'Green' } elseif ($ok -eq $false) { 'Yellow' } else { 'Gray' }) }

$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'Run this as Administrator.' -ForegroundColor Red; exit 1 }

# 1. installed?
$svc = Get-Service ServerAdminSvc -ErrorAction SilentlyContinue
if (-not $svc) { Write-Host 'Server Admin Suite is not installed on this server.' -ForegroundColor Red; exit 1 }
Say $true "Suite installed (service $($svc.Status))"

# 2. configuration: module on, folders, who is recorded
if (-not (Test-Path $cfgPath)) { Write-Host "No configuration at $cfgPath - open the dashboard once, then run this again." -ForegroundColor Red; exit 1 }
Copy-Item $cfgPath "$cfgPath.before-repair" -Force
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$changed = $false
if (-not $cfg.Modules.FileMonitor) { $cfg.Modules.FileMonitor = $true; $changed = $true; Say $false 'File activity was switched off - switched on' } else { Say $true 'File activity switched on' }

$roots = @($cfg.WatchRoots | Where-Object { $_ })
$good = @($roots | Where-Object { Test-Path -LiteralPath $_ })
$bad = @($roots | Where-Object { -not (Test-Path -LiteralPath $_) })
foreach ($b in $bad) { Say $false "Watched folder not found on this server: $b (removed)" }
if ($good.Count -eq 0) {
    $sys = $env:SystemDrive + '\'
    $good = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID + '\' } | Where-Object { $_ -ne $sys })
    if ($good.Count -eq 0) { $good = @('C:\Users'); Say $false 'No data drive on this server - watching C:\Users (user Desktops / Documents)' }
    else { Say $false "No usable folder chosen - watching the data drives: $($good -join ', ')" }
}
if ($bad.Count -gt 0 -or $roots.Count -ne $good.Count) { $cfg.WatchRoots = $good; $changed = $true }
Say $true "Watching: $($good -join ', ')"

# users of this server who are administrators would be hidden: record them too
$admins = @(Get-LocalGroupMember -SID S-1-5-32-544 -ErrorAction SilentlyContinue | ForEach-Object { ($_.Name -split '\\')[-1] })
$rdpUsers = @(quser 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_.TrimStart(' >') -split '\s+')[0] })
$adminUsers = @($rdpUsers | Where-Object { $admins -contains $_ -and $_ -notmatch '^(administrator|admin)$' })
if ($cfg.FileActivityExcludeAdmins -and $adminUsers.Count -gt 0) {
    $cfg.FileActivityExcludeAdmins = $false; $changed = $true
    Say $false "Signed-in users who are administrators ($($adminUsers -join ', ')) were hidden - they are recorded now"
} else { Say $true 'Who is recorded: OK' }

if ($changed) { $cfg | ConvertTo-Json -Depth 20 | Set-Content $cfgPath -Encoding UTF8; Say $null "Configuration saved (backup: $cfgPath.before-repair)" }

# 3. Windows auditing (names the user; without it the signed-in user is recorded)
& reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa' /v SCENoApplyLegacyAuditPolicy /t REG_DWORD /d 1 /f | Out-Null
& auditpol.exe /set /subcategory:'{0CCE921D-69AE-11D9-BED3-505054503030}' /success:enable | Out-Null
& auditpol.exe /set /subcategory:'{0CCE9223-69AE-11D9-BED3-505054503030}' /success:enable | Out-Null
Say $true 'Windows file auditing switched on'

# 4. (re)start the service
Restart-Service ServerAdminSvc -Force -ErrorAction SilentlyContinue
(Get-Service ServerAdminSvc).WaitForStatus('Running', '00:00:40')
Start-Sleep 8
$st = Get-Content (Join-Path $data 'filemonitor-status.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
if ($st -and -not $st.Licensed) { Say $false 'THIS SERVER IS NOT ACTIVATED - recording is paused. Activate it in the dashboard (Admin page).' }
elseif ($st -and $st.Running) { Say $true "File monitor running on: $($st.Roots -join ', ')" }
else { Say $false 'File monitor did not start - see the service log lines below' }

# 5. live test: a change in the first watched folder must reach the activity log
$testDir = $good[0]
$test = Join-Path $testDir ("_sas_test_{0}.txt" -f (Get-Date -Format 'HHmmss'))
$logDir = Join-Path $data 'activity'
$before = (Get-ChildItem $logDir -Filter 'activity-*.csv' -ErrorAction SilentlyContinue | Get-Content -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
try { Set-Content $test 'Server Admin Suite file activity test' -ErrorAction Stop; Start-Sleep 2; Add-Content $test 'changed'; Start-Sleep 2; Remove-Item $test -Force } catch { Say $false "Could not write a test file in $testDir : $($_.Exception.Message)" }
Start-Sleep 12
$st = Get-Content (Join-Path $data 'filemonitor-status.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
$after = (Get-ChildItem $logDir -Filter 'activity-*.csv' -ErrorAction SilentlyContinue | Get-Content -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
if ($st) { Say $null "Changes seen: $($st.Seen), recorded: $($st.Recorded), skipped (only admins signed in): $($st.SkippedAdmins), skipped (nobody signed in): $($st.SkippedNobody)" }
if ($after -gt $before) { Say $true "TEST PASSED - the test change was recorded. File activity works." }
elseif ($st -and $st.Seen -gt 0) { Say $null 'The test change was SEEN. It is recorded for a signed-in standard user - this script runs as an administrator, so check the page after a user changes a file.' }
else { Say $false 'The test change was NOT seen by the file monitor - send the report below.' }

$report.Add(''); $report.Add('--- service log (last 25 lines) ---')
Get-Content (Join-Path $data 'service.log') -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { $report.Add($_) }
$out = Join-Path $data 'fileactivity-repair.txt'
$report | Set-Content $out -Encoding UTF8
Write-Host "`nReport saved: $out" -ForegroundColor Cyan
