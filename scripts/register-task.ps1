# register-task.ps1 — run in Windows PowerShell as the Windows user who owns WSL.
# Creates a hidden task that runs the Linux user's keep-alive and re-checks every
# 5 minutes (WSL updates / wsl --shutdown kill everything; IgnoreNew makes the
# 5-minute run a no-op while the keep-alive is still alive).
#
# Two modes:
#   * Elevated PowerShell ("Run as administrator")  -> runs at BOOT, no logon needed,
#     so pi-web comes back after a Windows Update restart. Uses S4U (no password
#     stored); add -UsePassword if WSL won't start under S4U on this machine.
#   * Normal PowerShell -> runs only while you are logged on (at logon + every 5 min).
#
#   powershell -ExecutionPolicy Bypass -File register-task.ps1 -LinuxUser alice
#   powershell -ExecutionPolicy Bypass -File register-task.ps1 -LinuxUser alice -UsePassword
#   powershell -ExecutionPolicy Bypass -File register-task.ps1 -LinuxUser alice -Remove
param(
    [Parameter(Mandatory = $true)][string]$LinuxUser,
    [string]$Distro = "Ubuntu",
    [switch]$UsePassword,
    [switch]$Remove
)

$name = "WSL pi-web keepalive ($LinuxUser)"

if ($Remove) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    "Removed task: $name"
    return
}

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$winUser = "$env:USERDOMAIN\$env:USERNAME"

$script = "/home/$LinuxUser/bin/piweb-keepalive.sh"
# conhost --headless: no console window pops up at logon
$a = New-ScheduledTaskAction -Execute "C:\Windows\System32\conhost.exe" `
    -Argument "--headless C:\Windows\System32\wsl.exe -d $Distro -u $LinuxUser --exec $script"
$every5 = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew -StartWhenAvailable

if ($elevated) {
    # Boot trigger + 5-minute check, run whether or not anyone is logged on
    $boot = New-ScheduledTaskTrigger -AtStartup
    $boot.Delay = "PT1M"   # let networking and the WSL service come up first
    if ($UsePassword) {
        $cred = Get-Credential -UserName $winUser -Message "Windows password for $winUser (stored by Task Scheduler)"
        Register-ScheduledTask -TaskName $name -Action $a -Trigger $boot, $every5 -Settings $s `
            -User $winUser -Password $cred.GetNetworkCredential().Password -RunLevel Limited -Force | Out-Null
        $mode = "boot, password logon"
    } else {
        $p = New-ScheduledTaskPrincipal -UserId $winUser -LogonType S4U -RunLevel Limited
        Register-ScheduledTask -TaskName $name -Action $a -Trigger $boot, $every5 -Settings $s `
            -Principal $p -Force | Out-Null
        $mode = "boot, S4U (no password stored)"
    }
} else {
    Write-Warning "Not elevated: the task will only run while $winUser is logged on. Re-run in an elevated PowerShell to survive Windows Update restarts."
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    Register-ScheduledTask -TaskName $name -Action $a -Trigger $logon, $every5 -Settings $s -Force | Out-Null
    $mode = "logon only"
}

# Don't let the WSL VM idle-shutdown (takes effect after the next WSL restart)
$wslconfig = Join-Path $env:USERPROFILE ".wslconfig"
if (-not (Test-Path $wslconfig) -or -not (Select-String -Path $wslconfig -Pattern "vmIdleTimeout" -Quiet)) {
    if (-not (Test-Path $wslconfig) -or -not (Select-String -Path $wslconfig -Pattern "^\[wsl2\]" -Quiet)) {
        Add-Content -Path $wslconfig -Value "[wsl2]"
    }
    Add-Content -Path $wslconfig -Value "vmIdleTimeout=-1"
    "Added vmIdleTimeout=-1 to $wslconfig"
}

# Older deployments used a task without the "(user)" suffix; drop it if it runs this user
Get-ScheduledTask -TaskName "WSL pi-web keepalive" -ErrorAction SilentlyContinue |
    Where-Object { $_.Actions.Arguments -match "-u $LinuxUser " } | ForEach-Object {
        Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false
        "Removed legacy task: $($_.TaskName)"
    }

# Replace any running watchdog with one owned by this task. WSL may reap what the
# old watchdog started (tmux, tailscaled); the new one recreates them within seconds.
& C:\Windows\System32\wsl.exe -d $Distro -u $LinuxUser --exec pkill -u $LinuxUser -f "^/bin/bash /home/$LinuxUser/bin/piweb-keepalive\.sh$" | Out-Null
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $name
"Task '$name' ($mode): " + (Get-ScheduledTask -TaskName $name).State
