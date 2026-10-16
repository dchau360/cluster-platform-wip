# Install (or remove) the Windows half of LAB_LAN_ACCESS. Run once, in an
# administrator PowerShell on the Windows lab host. Safe to run again.
#
#   .\install-lan-route.ps1 -Subnet <PROV_SUBNET> -LanCidr <LAB_LAN_CIDR> -LanInterface Wi-Fi
#
# `make lan-access` on the head node prints this line with your values filled in.
#   .\install-lan-route.ps1 -Uninstall
#
# It does three things:
#   1. copies cluster-lan-route.ps1 to C:\ProgramData\cluster-lab\
#   2. registers the task "cluster-lab LAN route" (SYSTEM, at boot and every
#      minute), which keeps forwarding on and the route to the subnet pointed
#      at WSL's current address
#   3. adds a Hyper-V firewall rule letting LanCidr reach the cluster subnet on
#      TCP 22. The WSL VM blocks all other inbound traffic by default, and the
#      head node's nftables rules repeat the same limit.
[CmdletBinding()]
param(
  [string] $Subnet,
  [string] $LanCidr,
  [string] $LanInterface,
  [switch] $Uninstall
)
$ErrorActionPreference = 'Stop'
$dir      = Join-Path $env:ProgramData 'cluster-lab'
$taskName = 'cluster-lab LAN route'
$ruleName = 'cluster-lab-lan-ssh'
$wslVm    = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'   # WSL's Hyper-V VM creator ID

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this from an administrator PowerShell.'
}

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
  Write-Output "Removed. Forwarding and the route stay until the next WSL restart or reboot."
  exit 0
}
if (-not ($Subnet -and $LanCidr -and $LanInterface)) {
  throw 'Give -Subnet (PROV_SUBNET), -LanCidr (LAB_LAN_CIDR) and -LanInterface (for example Wi-Fi or Ethernet).'
}
Get-NetAdapter -Name $LanInterface -ErrorAction Stop | Out-Null

New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'cluster-lan-route.ps1') $dir
$script = Join-Path $dir 'cluster-lan-route.ps1'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
  "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" " +
  "-Subnet $Subnet -LanInterface `"$LanInterface`"")
$every = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
$boot  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Force -Action $action -Trigger $boot, $every `
  -Settings $settings -User 'SYSTEM' -RunLevel Highest `
  -Description 'Keeps the home LAN able to reach the cluster subnet through WSL (cluster-platform-wip)' | Out-Null

Remove-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue
New-NetFirewallHyperVRule -Name $ruleName -DisplayName 'cluster-lab: home LAN SSH to cluster' `
  -Direction Inbound -VMCreatorId $wslVm -Action Allow -Protocol TCP -LocalPorts 22 `
  -RemoteAddresses $LanCidr -LocalAddresses $Subnet | Out-Null

Start-ScheduledTask -TaskName $taskName
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Subnet $Subnet -LanInterface $LanInterface
Write-Output "Installed. Now add a route on your router: $Subnet via this host's address on $LanInterface."
