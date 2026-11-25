param([Parameter(Mandatory)][string]$InstallRoot)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$runtime = $PSScriptRoot
$enabled = Join-Path $runtime 'apex-auto.enabled'
$lockPath = Join-Path $runtime 'apex-auto.lock'
$log = Join-Path $runtime 'apex-auto.log'
$matchLists = @(
    (Join-Path $runtime 'ipset-apex-auto-game.txt')
    (Join-Path $runtime 'ipset-apex-auto-sdr.txt')
)
# An empty include list matches everything in winws. Keep a non-routable address.
$placeholder = '192.0.2.1'
. "$PSScriptRoot\service-state.ps1"

function Write-ApexAutoDecision([string]$Endpoint, [string]$Message) {
    try {
        $path = Join-Path $runtime 'apex-auto-decisions.log'
        $previous = "$path.old"
        $row = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Endpoint  $Message" + [Environment]::NewLine
        $entry = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($entry.Length + [Text.Encoding]::UTF8.GetByteCount($row) -gt 64KB) {
            Move-Item -LiteralPath $path -Destination $previous -Force
        }
        [IO.File]::AppendAllText($path, $row, [Text.Encoding]::UTF8)
    } catch {
        # A log error must not stop capture or update of the IP lists.
    }
}

function Open-AutoLock {
    try { [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] {
        if (($_.Exception.GetBaseException().HResult -band 0xffff) -in 32,33) { return }
        throw
    }
}

function Write-ApexAutoList([string]$Path, [string[]]$Addresses) {
    $entries = [string[]](@($placeholder) + @($Addresses | Sort-Object))
    if (((Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) -join ',') -ceq ($entries -join ',')) { return }
    $temp = "$($Path).$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllLines($temp, $entries, [Text.Encoding]::ASCII)
        [IO.File]::Replace($temp, $Path, "$temp.bak")
    } finally {
        Remove-Item -LiteralPath $temp,"$temp.bak" -ErrorAction SilentlyContinue
    }
}


function Set-ApexMatchRules([bool]$Enabled) {
    $addresses = if ($Enabled) { '0.0.0.0/1', '128.0.0.0/1' } else { @() }
    foreach ($path in $matchLists) { Write-ApexAutoList $path @($addresses) }
}

function Test-ApexAutoService {
    $service = Get-ZapretService
    return $service.Status -eq 'Running' -and $service.Profile -eq 'Apex' -and
        (Test-ZapretOwner $service $InstallRoot) -and $service.Command.Contains($matchLists[0]) -and
        $service.Command.Contains($matchLists[1])
}

$lock = Open-AutoLock
if (-not $lock) { return }
$active = $false
try {
    Remove-Item -LiteralPath "$enabled.ready" -ErrorAction SilentlyContinue
    Set-ApexMatchRules $false
    New-Item -ItemType File -Path "$enabled.ready" -Force | Out-Null
    $session = (Get-Process -Id $PID).SessionId
    while (Test-Path -LiteralPath $enabled) {
        $gameOpen = [bool](Get-Process -Name r5apex,r5apex_dx12 -ErrorAction SilentlyContinue |
            Where-Object SessionId -eq $session | Select-Object -First 1)
        $nextActive = $gameOpen -and (Test-ApexAutoService)
        if ($nextActive -ne $active) {
            Set-ApexMatchRules $nextActive
            $active = $nextActive
            if ($active) {
                Write-ApexAutoDecision 'Apex' 'Помощь включена. UDP 10000–11000 и 27015–27140, все IPv4.'
            } else {
                Write-ApexAutoDecision 'Apex' 'Помощь выключена.'
            }
        }
        Start-Sleep -Seconds 1
    }
} catch {
    $_.Exception.Message | Set-Content -LiteralPath $log -Encoding UTF8
    throw
} finally {
    try {
        Set-ApexMatchRules $false
        if ($active) { Write-ApexAutoDecision 'Apex' 'Помощь выключена.' }
    } finally {
        Remove-Item -LiteralPath "$enabled.ready" -ErrorAction SilentlyContinue
        $lock.Dispose()
    }
}
