$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$report = Join-Path $root 'Apex Network Report.txt'

$game = @(Get-Process -Name r5apex,r5apex_dx12 -ErrorAction SilentlyContinue)
if ($game.Count -eq 0) { throw 'Открой Apex и дойди до лобби.' }
if (-not (Get-Process -Name winws -ErrorAction SilentlyContinue)) {
    throw 'Сначала запусти профиль Apex.'
}

. "$PSScriptRoot\apex-udp-capture.ps1"
[ApexUdpCapture]::ValidateFilter()

$gameIds = @($game.Id)
$initialPorts = @(Get-NetUDPEndpoint -OwningProcess $gameIds -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty LocalPort)
$capture = [ApexUdpCapture]::new([int[]]$initialPorts)
$tcp = @{}
try {
    Write-Host 'Попробуй зайти в игру. Запись идёт 40 секунд.'
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    do {
        $ports = @(Get-NetUDPEndpoint -OwningProcess $gameIds -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty LocalPort)
        $capture.SetPorts([int[]]$ports)
        foreach ($connection in Get-NetTCPConnection -OwningProcess $gameIds -RemotePort 9000 -ErrorAction SilentlyContinue) {
            $address = $connection.RemoteAddress
            if (-not $tcp.ContainsKey($address)) {
                $route = Find-NetRoute -RemoteIPAddress $address -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSObject.Properties['DestinationPrefix'] } | Select-Object -First 1
                $tcp[$address] = @{
                    Interface = $route.InterfaceAlias
                    States = [Collections.Generic.HashSet[string]]::new()
                }
            }
            [void]$tcp[$address].States.Add([string]$connection.State)
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    $flows = $capture.Finish()
} finally {
    $capture.Dispose()
}

$lines = @("Apex Legends | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')", '', 'IPv4 UDP')
if ($flows.Count -eq 0) {
    $lines += 'No IPv4 UDP traffic matched the observed Apex sockets.'
} else {
    $lines += ($flows.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Remote = $_.Key; Sent = $_.Value[0]; Received = $_.Value[1] }
    } | Sort-Object Sent -Descending | Format-Table -AutoSize | Out-String -Width 160).TrimEnd()
}
$lines += '', 'TCP 9000'
if ($tcp.Count) {
    $lines += ($tcp.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{
            Remote = $_.Key
            Interface = $_.Value.Interface
            States = ($_.Value.States | Sort-Object) -join ', '
        }
    } | Sort-Object Remote | Format-Table -AutoSize | Out-String -Width 160).TrimEnd()
} else {
    $lines += 'No TCP 9000 connections observed.'
}
$lines | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "Отчёт сохранён. $report"
