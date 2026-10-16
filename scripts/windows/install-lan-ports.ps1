# The Windows half of LAN_PORT_FORWARDS: let devices on the home network reach
# the cluster through this host.
#
# For each port: a netsh portproxy entry from 0.0.0.0:<port> to
# 127.0.0.1:<port+Offset>, which WSL's localhost forwarding carries into the
# head node, where scripts/lan-ports.sh has a relay listening. One Windows
# Firewall rule admits those ports from the home LAN only.
#
# Nothing here names a WSL address, so a WSL restart or a Windows reboot
# leaves it correct. portproxy entries persist in the registry; the IP Helper
# service that serves them is set to start automatically.
#
# Run elevated. `make lan-ports` on the head node prints the exact command:
#
#   .\install-lan-ports.ps1 -Ports 2200,2201,8000 -LanCidr 192.0.2.0/24
#   .\install-lan-ports.ps1 -Uninstall
#
# Re-running converges: ports dropped from -Ports are removed.

[CmdletBinding()]
param(
  [int[]]$Ports,
  [string]$LanCidr,
  [int]$Offset = 30000,
  [string]$RuleName = 'cluster-lab LAN ports',
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this from an elevated PowerShell.'
}

# Ours: a listener on 0.0.0.0 that connects to 127.0.0.1 at listenport+Offset.
# Any other portproxy entry on this host is left alone.
$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp'
$ours = @()
if (Test-Path $key) {
  $entries = Get-ItemProperty $key
  foreach ($p in $entries.PSObject.Properties) {
    if ($p.Name -match '^0\.0\.0\.0/(\d+)$') {
      $port = [int]$Matches[1]
      if ($p.Value -eq "127.0.0.1/$($port + $Offset)") { $ours += $port }
    }
  }
}

$keep = @()
if (-not $Uninstall) {
  if (-not $Ports) { throw 'Pass -Ports (make lan-ports prints them), or -Uninstall.' }
  if ([string]::IsNullOrWhiteSpace($LanCidr)) { throw 'Pass -LanCidr, your home network, e.g. 192.0.2.0/24.' }
  $keep = $Ports
}

foreach ($port in $ours) {
  if ($keep -notcontains $port) {
    netsh interface portproxy delete v4tov4 listenport=$port listenaddress=0.0.0.0 | Out-Null
    Write-Host "removed  0.0.0.0:$port"
  }
}
Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule

if ($Uninstall) {
  Write-Host 'LAN port forwards removed.'
  return
}

foreach ($port in $Ports) {
  if ($port -lt 1024 -or ($port + $Offset) -gt 65535) { throw "Port $port is out of range." }
  netsh interface portproxy add v4tov4 listenport=$port listenaddress=0.0.0.0 `
    connectport=$($port + $Offset) connectaddress=127.0.0.1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "netsh could not add port $port." }
  Write-Host "forward  0.0.0.0:$port -> 127.0.0.1:$($port + $Offset)"
}

# portproxy is served by the IP Helper service.
Set-Service iphlpsvc -StartupType Automatic
Start-Service iphlpsvc

# Profile Any: home Wi-Fi is often classed Public. RemoteAddress is what
# keeps this to the home network.
New-NetFirewallRule -DisplayName $RuleName `
  -Description 'Cluster lab: LAN access to the head node and nodes. scripts/windows/install-lan-ports.ps1' `
  -Direction Inbound -Protocol TCP -LocalPort $Ports -RemoteAddress $LanCidr `
  -Action Allow -Profile Any | Out-Null
Write-Host "firewall '$RuleName': TCP $($Ports -join ',') from $LanCidr"
