# Keep the Windows half of LAB_LAN_ACCESS in place: IP forwarding between the
# LAN adapter and the WSL adapter, and a route to the cluster subnet via WSL.
#
# WSL recreates its virtual adapter, with a new address, every time it starts,
# so a one-off setting does not survive. install-lan-route.ps1 registers this
# script as a SYSTEM task that runs at boot and every minute. Each run checks
# and only changes what is wrong, and logs every change to the event log.
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Subnet,       # PROV_SUBNET, e.g. 10.44.0.0/22
  [Parameter(Mandatory)] [string] $LanInterface  # Windows adapter on the home LAN, e.g. Wi-Fi
)
$ErrorActionPreference = 'Stop'
$source = 'cluster-lab'
if (-not [Diagnostics.EventLog]::SourceExists($source)) {
  New-EventLog -LogName Application -Source $source
}
function Changed([string] $msg) {
  Write-Output "changed: $msg"
  Write-EventLog -LogName Application -Source $source -EventId 1 -EntryType Information -Message $msg
}

$wsl = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like 'vEthernet (WSL*' -and $_.Status -eq 'Up' } |
  Select-Object -First 1
if (-not $wsl) { Write-Output 'WSL is not running; nothing to do'; exit 0 }

$lan = Get-NetAdapter -Name $LanInterface -ErrorAction Stop

foreach ($ifIndex in @($wsl.ifIndex, $lan.ifIndex)) {
  $ip = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4
  if ($ip.Forwarding -ne 'Enabled') {
    Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Forwarding Enabled
    Changed "IPv4 forwarding enabled on $($ip.InterfaceAlias)"
  }
}

# The WSL VM is the only unicast neighbour on its adapter, and it is always
# talking (DNS, NAT), so its entry is there within seconds of WSL starting.
$hostAddr = (Get-NetIPAddress -InterfaceIndex $wsl.ifIndex -AddressFamily IPv4).IPAddress
$vm = Get-NetNeighbor -InterfaceIndex $wsl.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object {
    $_.State -in 'Reachable', 'Stale', 'Delay', 'Probe' -and
    $_.LinkLayerAddress -ne 'FF-FF-FF-FF-FF-FF' -and
    $_.IPAddress -ne $hostAddr -and
    [int]($_.IPAddress.Split('.')[0]) -lt 224
  } | Select-Object -First 1
if (-not $vm) { Write-Output 'WSL address not learned yet; next run retries'; exit 0 }
$nextHop = $vm.IPAddress

$routes = @(Get-NetRoute -DestinationPrefix $Subnet -AddressFamily IPv4 -ErrorAction SilentlyContinue)
$good = $routes | Where-Object { $_.NextHop -eq $nextHop -and $_.ifIndex -eq $wsl.ifIndex }
if (-not $good) {
  $routes | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  New-NetRoute -DestinationPrefix $Subnet -InterfaceIndex $wsl.ifIndex -NextHop $nextHop `
    -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
  Changed "route $Subnet via $nextHop (WSL)"
}
Write-Output "ok: $Subnet via $nextHop, forwarding on $($wsl.Name) and $LanInterface"
