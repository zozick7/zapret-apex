param(
    [ValidateSet('Refresh', 'Install', 'Remove', 'Run')]
    [string] $Action = 'Refresh'
)

$ErrorActionPreference = 'Stop'
$taskName = 'Zapret Apex Maintenance'
$root = Split-Path -Parent $PSScriptRoot

if ($Action -eq 'Install') {
    $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powershell = Join-Path $PSHOME 'powershell.exe'
    $arguments = '-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
        $PSCommandPath + '" -Action Run'
    $taskAction = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
    $principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    return
}

if ($Action -eq 'Remove') {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    return
}

function Update-ApexRelays {
    $cache = Join-Path $env:USERPROFILE 'Saved Games\Respawn\Apex\assets\temp\netcfg'
    if (-not (Test-Path -LiteralPath $cache -PathType Leaf)) { return }

    $list = Join-Path $root 'lists\ipset-apex-sdr.txt'
    $bundledRevision = 1794268433L
    $currentRevision = $bundledRevision
    $firstLine = Get-Content -LiteralPath $list -TotalCount 1
    if ($firstLine -match '^# revision: (\d+)$') { $currentRevision = [long]$Matches[1] }

    $data = Get-Content -LiteralPath $cache -Raw | ConvertFrom-Json
    $revision = [long]$data.revision
    if ($revision -le $currentRevision -or -not $data.pops) { return }

    $addresses = @(
        $data.pops.PSObject.Properties | ForEach-Object { $_.Value.relays } |
            ForEach-Object {
                $address = $null
                if ([Net.IPAddress]::TryParse([string]$_.ipv4, [ref]$address) -and
                    $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                    $_.port_range.Count -eq 2 -and $_.port_range[0] -le 27140 -and
                    $_.port_range[1] -ge 27015) {
                    $address.ToString()
                }
            } | Sort-Object -Unique
    )
    if ($addresses.Count -lt 20 -or $addresses.Count -gt 4096) {
        throw 'В новом списке ретрансляторов Apex необычное число адресов.'
    }

    $token = [guid]::NewGuid().ToString('N')
    $pending = "$list.$token.tmp"
    $backup = "$list.$token.bak"
    try {
        [IO.File]::WriteAllLines($pending, @("# revision: $revision") + $addresses, [Text.Encoding]::ASCII)
        [IO.File]::Replace($pending, $list, $backup)
        Write-Host "Список ретрансляторов Apex обновлён ($($addresses.Count) адресов)."
    } finally {
        Remove-Item -LiteralPath $pending,$backup -ErrorAction SilentlyContinue
    }
}

try {
    Update-ApexRelays
} catch {
    Write-Warning "Не удалось обновить список ретрансляторов Apex. $($_.Exception.Message)"
}

if ($Action -eq 'Run') {
    try { & "$PSScriptRoot\updates.ps1" -Quiet } catch { Write-Warning $_.Exception.Message }
}