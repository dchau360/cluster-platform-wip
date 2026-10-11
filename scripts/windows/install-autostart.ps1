# Make the lab survive a Windows reboot.
#
# WSL does not boot with Windows. It starts when something first enters the
# distribution, so a reboot leaves the lab down until a human opens a
# shell. This registers a logon task that enters the distribution once,
# which is enough for systemd to start and for lab.target to come up with
# it.
#
# Run once, in an elevated PowerShell on the Windows side:
#
#   .\install-autostart.ps1                 # uses the default distro name
#   .\install-autostart.ps1 -Distro Ubuntu  # or name it
#
# No host-specific value is baked in: the distribution name is a parameter
# and the task runs as whoever is logged on.

[CmdletBinding()]
param(
  [string]$Distro = $env:LAB_WSL_DISTRO,
  [string]$TaskName = 'ClusterLabWslBoot'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Distro)) { $Distro = 'Ubuntu' }

if (-not (wsl.exe -l -q | Where-Object { $_.Trim() -eq $Distro })) {
  throw "WSL distribution '$Distro' not found. Pass -Distro <name>."
}

# Entering the distribution is all that is needed. systemd does the rest,
# because every lab service is a unit enabled at boot.
$action = New-ScheduledTaskAction `
  -Execute 'wsl.exe' `
  -Argument "-d $Distro -- /bin/true"

$trigger  = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Description "Boot the WSL distribution '$Distro' at logon so the cluster lab comes back after a reboot." `
  -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName' for distribution '$Distro'."
Write-Host "Verify with:  Get-ScheduledTask -TaskName $TaskName"
Write-Host "Then inside WSL:  make cold-start-check"
