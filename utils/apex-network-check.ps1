$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$report = Join-Path $root 'Apex Network Report.txt'

$game = @(Get-Process -Name r5apex,r5apex_dx12 -ErrorAction SilentlyContinue)
if ($game.Count -eq 0) { throw 'Открой Apex и дойди до лобби.' }
if (-not (Get-Process -Name winws -ErrorAction SilentlyContinue)) {
    throw 'Сначала запусти профиль Apex.'
}

. "$PSScriptRoot\service-state.ps1"
$autoDir = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Zapret Apex\Apex Auto'

function Get-ApexReportStatus {
    $service = Get-ZapretService
    $owned = $service.Status -eq 'Running' -and $service.Profile -eq 'Apex' -and (Test-ZapretOwner $service $root)
    $serviceText = if ($owned) { 'Apex запущен из этой папки' }
        elseif ($service.Status -ne 'Running') { 'Служба выключена' }
        elseif ($service.Profile -ne 'Apex') { "Запущен другой профиль: $($service.Profile)" }
        else { 'Профиль Apex запущен из другой папки' }
    $file = Join-Path $autoDir 'ipset-apex-auto-match.txt'
    $ranges = if ($owned -and $service.Command -like "*$file*") {
        Get-Content -LiteralPath $file -ErrorAction SilentlyContinue
    }
    $wide = if ('0.0.0.0/1' -in $ranges -and '128.0.0.0/1' -in $ranges) {
        'оба диапазона включены'
    } else { 'широкие правила выключены' }
    [pscustomobject]@{ Service = $serviceText; Wide = $wide }
}

. "$PSScriptRoot\apex-udp-capture.ps1"
[ApexUdpCapture]::ValidateFilter()

$gameIds = @($game.Id)
$initialPorts = @(Get-NetUDPEndpoint -OwningProcess $gameIds -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty LocalPort)
$capture = [ApexUdpCapture]::new([int[]]$initialPorts)
$tcp = @{}
$started = Get-Date
$helpBefore = Get-ApexReportStatus
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

$interfaces = @{}
Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object {
    $interfaces[[int]$_.InterfaceIndex] = $_.InterfaceAlias
}
$udp = @($flows.GetEnumerator() | ForEach-Object {
    $endpoint, $index = $_.Key -split '\|',2
    $port = [int]($endpoint -split ':')[-1]
    $interface = $interfaces[[int]$index]
    [pscustomobject]@{
        Адрес = $endpoint
        Интерфейс = if ($interface) { $interface } else { "Индекс $index" }
        Отправлено = $_.Value[0]
        Получено = $_.Value[1]
        ИгровойПорт = ($port -ge 10000 -and $port -le 11000) -or ($port -ge 27015 -and $port -le 27140)
    }
} | Sort-Object @{Expression='ИгровойПорт';Descending=$true},@{Expression='Отправлено';Descending=$true})
$gameUdp = @($udp | Where-Object { $_.ИгровойПорт -and $_.Отправлено -gt 0 })
$noReply = @($gameUdp | Where-Object Получено -eq 0)
$withReply = @($gameUdp | Where-Object Получено -gt 0)
$helpAfter = Get-ApexReportStatus
$lines = @(
    "Apex Legends | $($started.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
    "Служба до записи: $($helpBefore.Service)"
    "Помощь при входе в матч: $($helpBefore.Wide) → $($helpAfter.Wide)"
    ''
)
if (-not $gameUdp.Count) {
    $lines += 'За время записи не видно исходящих пакетов Apex на игровых портах UDP.'
} else {
    $lines += "Игровой UDP по интерфейсам: с ответом $($withReply.Count), без ответа $($noReply.Count)."
    if ($noReply.Count) {
        $flow = $noReply[0]
        $lines += "Больше всего пакетов без ответа: $($flow.Адрес) через $($flow.Интерфейс), отправлено $($flow.Отправлено)."
    }
}
if ($udp.Count) {
    $lines += '', 'IPv4 UDP'
    $lines += ($udp | Select-Object -First 40 Адрес,Интерфейс,Отправлено,Получено |
        Format-Table -AutoSize | Out-String -Width 160).TrimEnd()
    if ($udp.Count -gt 40) { $lines += "Ещё адресов в записи: $($udp.Count - 40)." }
}

$lines += '', 'TCP 9000'
if ($tcp.Count) {
    $lines += ($tcp.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{
            Адрес = $_.Key
            Интерфейс = $_.Value.Interface
            Состояние = ($_.Value.States | Sort-Object) -join ', '
        }
    } | Sort-Object Адрес | Format-Table -AutoSize | Out-String -Width 160).TrimEnd()
} else {
    $lines += 'Соединений Apex на TCP 9000 за время записи не было видно.'
}
$autoLog = Join-Path $autoDir 'apex-auto-decisions.log'
$firstEvent = $started.ToString('yyyy-MM-dd HH:mm:ss')
$events = @(Get-Content -LiteralPath $autoLog -Encoding UTF8 -Tail 24 -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -ge 19 -and $_.Substring(0,19) -ge $firstEvent })
if ($events.Count) {
    $lines += '', 'Помощь Apex во время записи'
    $lines += $events
}
$errorLog = Get-Item -LiteralPath (Join-Path $autoDir 'apex-auto.log') -ErrorAction SilentlyContinue
if ($errorLog -and $errorLog.LastWriteTime -ge $started) {
    $lines += '', 'Ошибка помощника Apex'
    $lines += Get-Content -LiteralPath $errorLog.FullName -Encoding UTF8 -Tail 1 -ErrorAction SilentlyContinue
}
$lines | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "Отчёт сохранён. $report"
