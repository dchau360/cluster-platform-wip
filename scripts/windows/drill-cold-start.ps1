# Cold-start recovery drill — the driver.
#
# The thing being restarted is the thing the lab scripts run inside, so the
# drill cannot be driven from within it: `wsl --shutdown` kills every process
# in the distribution, including the script that asked for it. Windows is the
# only place that survives, so the three steps are driven from here.
#
# Run from the Windows side:
#
#   .\drill-cold-start.ps1 -Repo /home/<user>/src/cluster-platform-wip
#   .\drill-cold-start.ps1 -Repo ... -Distro Ubuntu -N 4
#
# No host-specific value is baked in: the distribution name, the repository
# path inside it and the node count are all parameters.
#
# This stops the whole distribution. Anything else running in it — another
# project's services, an editor, a CI runner — stops with it and comes back
# only if its unit is enabled at boot. Know what else is in the distribution
# before running this.

[CmdletBinding()]
param(
  [string]$Distro = $env:LAB_WSL_DISTRO,
  [Parameter(Mandatory = $true)][string]$Repo,
  [string]$N = '',
  [int]$SettleSeconds = 10
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Distro)) { $Distro = 'Ubuntu' }

if (-not (wsl.exe -l -q | Where-Object { $_.Trim() -eq $Distro })) {
  throw "WSL distribution '$Distro' not found. Pass -Distro <name>."
}

$nodeCount = if ([string]::IsNullOrWhiteSpace($N)) { '' } else { "N=$N " }

function Invoke-Stage([string]$Stage) {
  Write-Host ""
  Write-Host "######## cold-start drill: $Stage ########"
  Write-Host ""
  # `bash -lc` so the stage runs with the login environment the operator's
  # own `make` would have.
  wsl.exe -d $Distro -- bash -lc "cd '$Repo' && ${nodeCount}bash scripts/drill-cold-start.sh $Stage"
  if ($LASTEXITCODE -ne 0) { throw "cold-start drill stage '$Stage' failed with exit code $LASTEXITCODE" }
}

Invoke-Stage 'before'

Write-Host ""
Write-Host "######## wsl --shutdown ########"
Write-Host ""
wsl.exe --shutdown
if ($LASTEXITCODE -ne 0) { throw "wsl --shutdown failed with exit code $LASTEXITCODE" }

# The shutdown returns before the VM has finished going away. Entering the
# distribution too early can attach to the one that is still stopping, which
# would leave the boot id unchanged and the drill would correctly refuse to
# call that a restart.
Write-Host "waiting ${SettleSeconds}s for the distribution to stop"
Start-Sleep -Seconds $SettleSeconds

# The first command to enter the distribution is what starts it again, and
# the drill's `after` stage is that command. It measures from here.
Invoke-Stage 'after'

Write-Host ""
Write-Host "cold-start drill complete."
