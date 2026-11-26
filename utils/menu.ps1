$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$psExe = Join-Path $PSHOME 'powershell.exe'
$menuArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try { Start-Process -FilePath $psExe -ArgumentList $menuArgs -Verb RunAs }
    catch { Write-Host 'Запусти меню с правами администратора.' }
    return
}

$root = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\service-state.ps1"
$manager = Join-Path $PSScriptRoot 'profile-manager.ps1'
$profiles = Join-Path $root 'profiles'
$current = (Get-Content -LiteralPath (Join-Path $root 'release.json') -Raw | ConvertFrom-Json).version
$selected = (Get-ZapretService).Profile
if ($selected -eq 'Rust-Facepunch') { $selected = 'Rust' }
if (-not $selected -or -not (Test-Path -LiteralPath (Join-Path $profiles "$selected.args") -PathType Leaf)) {
    $selected = 'ALT11'
}

$Host.UI.RawUI.WindowTitle = 'Zapret'
$messages = [Collections.Generic.List[object]]::new()

function Add-MenuMessage([string]$Text, [ConsoleColor]$Color = 'Gray') {
    if (-not $Text.Trim()) { return }
    $messages.Add([pscustomobject]@{ Text = $Text; Color = $Color })
    if ($messages.Count -gt 6) { $messages.RemoveAt(0) }
}

function Invoke-MenuAction([scriptblock]$Action) {
    & $Action 3>&1 6>&1 | ForEach-Object {
        if ($_ -is [bool]) {
            $script:updated = $_
        } else {
            $color = 'Gray'
            if ($_ -is [Management.Automation.WarningRecord]) { $color = 'Yellow' }
            $line = [string]$_
            Add-MenuMessage $line $color
            Write-Host $line -ForegroundColor $color
        }
    }
}

function Get-ProfileLabel([string]$Name) {
    switch ($Name) {
        'Apex' { 'Apex Legends' }
        'ALT11' { 'Discord и YouTube' }
        default { $Name }
    }
}

function Assert-ZapretServiceOwner($Service) {
    if ($Service -and -not (Test-ZapretOwner $Service $root) -and -not (Test-ZapretManagedService $Service)) {
        throw 'Служба принадлежит другой сборке Zapret. Открой её меню.'
    }
}

while ($true) {
    Clear-Host
    Write-Host "Zapret $current" -ForegroundColor Cyan
    foreach ($message in $messages) {
        Write-Host $message.Text -ForegroundColor $message.Color
    }
    $service = Get-ZapretService
    $running = $service.Status -eq 'Running'
    $status = if ($running) { 'включён' } else { 'выключен' }
    if ($service) {
        if (-not (Test-ZapretOwner $service $root)) {
            if (Test-ZapretManagedService $service) { $status += ', прежняя папка' }
            else { $status += ', другая сборка' }
        }
    }
    Write-Host ''
    Write-Host "Профиль  $(Get-ProfileLabel $selected)"
    Write-Host "Zapret   $status"
    $updates = Join-Path (Get-ZapretProtectedRoot) 'Updates'
    $ready = Get-Content -LiteralPath (Join-Path $updates 'ready-version.txt') -TotalCount 1 -ErrorAction SilentlyContinue
    if ($ready -match '^v(\d+\.\d+\.\d+)$' -and [version]$Matches[1] -gt [version]$current) {
        $notice = "Доступно $ready"
        $summaryPath = Join-Path (Join-Path $updates $ready) 'release-summary.txt'
        $summary = Get-Content -LiteralPath $summaryPath -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($summary) {
            $summary = ($summary -replace '[\p{C}\p{Zl}\p{Zp}]+', ' ').Trim()
            if ($summary) { $notice += "  $summary" }
        }
        try { $width = [Console]::WindowWidth } catch { $width = 80 }
        $limit = if ($width -gt 0) { [Math]::Min(88, $width - 1) } else { 79 }
        if ($notice.Length -gt $limit -and $limit -gt 1) {
            $notice = $notice.Substring(0, $limit - 1).TrimEnd() + '…'
        }
        Write-Host $notice -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  1  Выбрать профиль'
    if ($running) { Write-Host '  2  Выключить' }
    else { Write-Host '  2  Включить' }
    Write-Host '  3  Проверить сеть'
    Write-Host '  4  Обновить'
    if ($selected -eq 'Apex') {
        Write-Host '  5  Записать отчёт о подключении'
        $auto = if (& "$PSScriptRoot\apex-auto.ps1" -Action Status) { 'вкл' } else { 'выкл' }
        Write-Host "  6  Помощь при входе в матч ($auto)"
    }
    elseif ($selected -eq 'Rust') { Write-Host '  5  Проверить карту Rust' }
    if ($service -and (Test-ZapretOwner $service $root)) { Write-Host '  8  Удалить службу' }
    Write-Host '  0  Выход'
    $choice = Read-Host 'Номер'
    if ($null -eq $choice -or $choice.Trim() -eq '0') { break }

    $messages.Clear()
    $choice = $choice.Trim()
    try {
        switch ($choice) {
            '1' {
                Clear-Host
                Write-Host 'Выбрать профиль' -ForegroundColor Cyan
                $names = @(Get-ChildItem -LiteralPath $profiles -File -Filter '*.args' |
                    Where-Object { $_.BaseName -ne 'Rust-Facepunch' -and $_.BaseName -match '^[a-zA-Z][a-zA-Z0-9_-]{0,31}$' } |
                    Sort-Object @{Expression={ if ($_.BaseName -eq 'ALT11') { 0 } elseif ($_.BaseName -eq 'Apex') { 1 } else { 2 } }}, BaseName |
                    Select-Object -ExpandProperty BaseName)
                for ($i = 0; $i -lt $names.Count; $i++) { Write-Host "  $($i + 1)  $(Get-ProfileLabel $names[$i])" }
                $inputChoice = Read-Host 'Профиль (0 для возврата)'
                $index = 0
                if ([int]::TryParse($inputChoice, [ref]$index) -and $index -ge 1 -and $index -le $names.Count) {
                    $next = $names[$index - 1]
                    if ($running -and $next -ne $service.Profile) {
                        Invoke-MenuAction { & $manager -Action Install -Profile $next }
                    }
                    $selected = $next
                } elseif ($inputChoice -and $inputChoice -ne '0') {
                    Add-MenuMessage 'Выбери номер из списка.' Yellow
                }
            }
            '2' {
                Assert-ZapretServiceOwner $service
                if ($running) {
                    Set-Service -Name zapret -StartupType Disabled
                    try {
                        Stop-Service -Name zapret
                        Wait-ZapretService Stopped
                    } catch {
                        switch ($service.Start) {
                            2 { Set-Service -Name zapret -StartupType Automatic }
                            3 { Set-Service -Name zapret -StartupType Manual }
                        }
                        throw
                    }
                    Invoke-MenuAction { & "$PSScriptRoot\network-check.ps1" -RemoveRepair }
                } else {
                    Invoke-MenuAction { & $manager -Action Install -Profile $selected }
                }
            }
            '3' {
                if (-not $running) {
                    Add-MenuMessage 'Сначала включи Zapret.' Yellow
                } else {
                    if ($service.Profile -eq 'Apex' -and (Test-ZapretOwner $service $root)) {
                        $maintenance = if ($service.RuntimeRoot) { Join-Path $service.RuntimeRoot 'utils\apex-maintenance.ps1' }
                            else { Join-Path $PSScriptRoot 'apex-maintenance.ps1' }
                        Invoke-MenuAction { & $maintenance -Action Refresh }
                    }
                    Invoke-MenuAction { & "$PSScriptRoot\network-check.ps1" -Profile $selected }
                }
            }
            '5' {
                if ($selected -eq 'Rust') { Invoke-MenuAction { & "$PSScriptRoot\rust-map-check.ps1" } }
                elseif ($selected -eq 'Apex') { Invoke-MenuAction { & "$PSScriptRoot\apex-network-check.ps1" } }
                else { Add-MenuMessage 'Выбери Apex или Rust для диагностики игры.' Yellow }
            }
            '6' {
                if ($selected -ne 'Apex') { Add-MenuMessage 'Выбери профиль Apex.' Yellow; break }
                $script = Join-Path $PSScriptRoot 'apex-auto.ps1'
                if (& $script -Action Status) {
                    & $script -Action Disable
                    Add-MenuMessage 'Помощь Apex выключена.'
                } else {
                    & $script -Action Enable
                    Add-MenuMessage 'Помощь Apex включена. Правила действуют, пока Apex открыт.'
                }
            }
            '8' {
                if (-not (Test-ZapretOwner $service $root)) { throw 'Открой меню из папки, где установлена служба.' }
                Invoke-MenuAction { & $manager -Action Remove }
            }
            { $_ -in '4','7' } {
                $script:updated = $false
                Invoke-MenuAction { & "$PSScriptRoot\updates.ps1" -Install }
                if ($script:updated) {
                    Start-Process -FilePath $psExe -ArgumentList $menuArgs
                    return
                }
            }
            default { Add-MenuMessage 'Нет такого пункта.' Yellow }
        }
    } catch { Add-MenuMessage $_.Exception.Message Red }
}
