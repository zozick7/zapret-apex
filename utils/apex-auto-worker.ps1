param([Parameter(Mandatory)][string]$InstallRoot)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$runtime = $PSScriptRoot
$enabled = Join-Path $runtime 'apex-auto.enabled'
$lockPath = Join-Path $runtime 'apex-auto.lock'
$log = Join-Path $runtime 'apex-auto.log'
$lists = Join-Path $InstallRoot 'lists'
$groups = @(
    @{ File = (Join-Path $runtime 'ipset-apex-auto-game.txt') }
    @{ File = (Join-Path $runtime 'ipset-apex-auto-sdr.txt') }
)
# An empty include list matches everything in winws. Keep a non-routable address.
$placeholder = '192.0.2.1'
$idleTimeout = [TimeSpan]::FromMinutes(10)
$autoFilter = 'ip and udp and not loopback and not fragment and not impostor and ' +
    '((outbound and ((udp.DstPort >= 10000 and udp.DstPort <= 11000) or (udp.DstPort >= 27015 and udp.DstPort <= 27140))) or ' +
    '(inbound and ((udp.SrcPort >= 10000 and udp.SrcPort <= 11000) or (udp.SrcPort >= 27015 and udp.SrcPort <= 27140))))'
. "$PSScriptRoot\service-state.ps1"

function Open-AutoLock {
    try { [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] {
        if (($_.Exception.GetBaseException().HResult -band 0xffff) -in 32,33) { return }
        throw
    }
}

function Write-ApexAutoList($Group, [string[]]$Addresses) {
    $entries = [string[]](@($placeholder) + @($Addresses | Sort-Object))
    if (((Get-Content -LiteralPath $Group.File -ErrorAction SilentlyContinue) -join ',') -ceq ($entries -join ',')) { return }
    $temp = "$($Group.File).$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllLines($temp, $entries, [Text.Encoding]::ASCII)
        [IO.File]::Replace($temp, $Group.File, "$temp.bak")
    } finally {
        Remove-Item -LiteralPath $temp,"$temp.bak" -ErrorAction SilentlyContinue
    }
}

function Reset-ApexAutoLists {
    foreach ($group in $groups) {
        $group.Learned = @{}
        if (Test-Path -LiteralPath $group.File -PathType Leaf) {
            Write-ApexAutoList $group @()
        }
    }
}

function Test-ApexAutoService {
    $service = Get-ZapretService
    return $service.Status -eq 'Running' -and $service.Profile -eq 'Apex' -and
        (Test-ZapretOwner $service $InstallRoot) -and $service.Command.Contains($groups[0].File) -and
        $service.Command.Contains($groups[1].File)
}

function ConvertTo-ApexAddressNumber([Net.IPAddress]$Address) {
    $bytes = $Address.GetAddressBytes()
    [array]::Reverse($bytes)
    [long][BitConverter]::ToUInt32($bytes, 0)
}

function Get-ApexAddressRanges([string[]]$Entries) {
    foreach ($entry in $Entries) {
        $parts = ($entry -split '#',2)[0].Trim() -split '/',2
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or
            $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { continue }
        $prefix = 32
        if ($parts.Count -eq 2 -and (-not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 32)) {
            continue
        }
        $offset = 32 - $prefix
        [pscustomobject]@{ Offset = $offset; Prefix = (ConvertTo-ApexAddressNumber $ip) -shr $offset }
    }
}

function Test-ApexAddressRange([long]$Address, $Ranges) {
    foreach ($range in $Ranges) {
        if (($Address -shr $range.Offset) -eq $range.Prefix) { return $true }
    }
    return $false
}

function Get-ApexKnownRanges {
    $files = 'ipset-apex-aws.txt','ipset-exclude.txt','ipset-exclude-user.txt'
    $shared = @(Get-Content -LiteralPath ($files | ForEach-Object { Join-Path $lists $_ }) -ErrorAction SilentlyContinue)
    $shared += '0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8','169.254.0.0/16',
        '172.16.0.0/12','192.0.0.0/24','192.0.2.0/24','192.168.0.0/16','198.18.0.0/15',
        '198.51.100.0/24','203.0.113.0/24','224.0.0.0/3'
    $groups[0].Known = @(Get-ApexAddressRanges ($shared + '54.115.0.0/16'))
    $relays = @(Get-Content -LiteralPath (Join-Path $lists 'ipset-apex-sdr.txt'))
    $groups[1].Known = @(Get-ApexAddressRanges ($shared + $relays))
}

function Update-ApexAutoLists($Flows, $Pending, [DateTime]$Now) {
    foreach ($group in $groups) { $group.Changed = $false }
    foreach ($flow in $Flows.GetEnumerator()) {
        $counts = $flow.Value
        if (-not $Pending.ContainsKey($flow.Key)) {
            $Pending[$flow.Key] = @{
                Sent = 0; Received = 0; AttemptSent = 0; Replied = $false
                LastActivity = $Now; Deadline = $null; Handled = $false
            }
        }
        $state = $Pending[$flow.Key]
        $sent = $counts[0] - $state.Sent
        $received = $counts[1] - $state.Received
        if ($sent -or $received) {
            if ($Now -ge $state.LastActivity.AddSeconds(8)) {
                $state.AttemptSent = 0
                $state.Replied = $false
                $state.Deadline = $null
                $state.Handled = $false
            }
            $state.LastActivity = $Now
            $state.Sent = $counts[0]
            $state.Received = $counts[1]
            $state.AttemptSent += $sent
            if ($received -gt 0) { $state.Replied = $true }
        }
        $address, $portText = ($flow.Key -split '/',2)[0] -split ':',2
        $port = [int]$portText
        $group = if ($port -ge 10000 -and $port -le 11000) { $groups[0] }
            elseif ($port -ge 27015 -and $port -le 27140) { $groups[1] }
        if (-not $group) { continue }
        if ($group.Learned.ContainsKey($address)) {
            if ($received -gt 0) { $group.Learned[$address] = $Now.Add($idleTimeout) }
            continue
        }
        if ($state.Replied -or $state.Handled -or $state.AttemptSent -lt 3) { continue }
        if (-not $state.Deadline) { $state.Deadline = $Now.AddSeconds(2) }
        if ($Now -lt $state.Deadline) { continue }

        if ($group.Learned.Count -ge 16) { continue }
        $state.Handled = $true
        $number = ConvertTo-ApexAddressNumber ([Net.IPAddress]::Parse($address))
        if (Test-ApexAddressRange $number $group.Known) { continue }
        $group.Learned[$address] = $Now.Add($idleTimeout)
        $group.Changed = $true
    }
    foreach ($group in $groups) {
        foreach ($address in @($group.Learned.Keys)) {
            if ($Now -ge $group.Learned[$address]) {
                $group.Learned.Remove($address)
                $group.Changed = $true
            }
        }
        if ($group.Changed) { Write-ApexAutoList $group @($group.Learned.Keys) }
    }
}

$lock = Open-AutoLock
if (-not $lock) { return }
$capture = $null
$gameKey = ''
try {
    Remove-Item -LiteralPath "$enabled.ready" -ErrorAction SilentlyContinue
    Reset-ApexAutoLists
    . "$PSScriptRoot\apex-udp-capture.ps1" -DllPath (Join-Path $runtime 'WinDivert.dll')
    [ApexUdpCapture]::ValidateFilter($autoFilter)
    New-Item -ItemType File -Path "$enabled.ready" -Force | Out-Null
    $session = (Get-Process -Id $PID).SessionId
    while (Test-Path -LiteralPath $enabled) {
        $game = @()
        if (Test-ApexAutoService) {
            $game = @(Get-Process -Name r5apex,r5apex_dx12 -ErrorAction SilentlyContinue |
                Where-Object SessionId -eq $session | Sort-Object Id)
        }
        $nextKey = $game.Id -join ','
        if ($nextKey -ne $gameKey) {
            if ($capture) { $capture.Dispose(); $capture = $null }
            $gameKey = $nextKey
            $pending = @{}
            if ($gameKey) { Get-ApexKnownRanges }
        }
        if (-not $gameKey) {
            Update-ApexAutoLists @{} @{} ([DateTime]::UtcNow)
            Start-Sleep -Seconds 2
            continue
        }

        $ports = @(Get-NetUDPEndpoint -OwningProcess $game.Id -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty LocalPort)
        if (-not $capture -and $ports.Count) { $capture = [ApexUdpCapture]::new([int[]]$ports, $autoFilter, $true) }
        if ($capture) {
            $capture.SetPorts([int[]]$ports)
            Update-ApexAutoLists ($capture.Snapshot()) $pending ([DateTime]::UtcNow)
        } else {
            Update-ApexAutoLists @{} @{} ([DateTime]::UtcNow)
        }
        Start-Sleep -Seconds 1
    }
} catch {
    $_.Exception.Message | Set-Content -LiteralPath $log -Encoding UTF8
    throw
} finally {
    try {
        if ($capture) { $capture.Dispose() }
        Reset-ApexAutoLists
    } finally {
        Remove-Item -LiteralPath "$enabled.ready" -ErrorAction SilentlyContinue
        $lock.Dispose()
    }
}
