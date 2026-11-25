param(
    [ValidateSet('Start','Install','Repair','Remove')]
    [string] $Action,
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,31}$')]
    [string] $Profile = 'Apex',
    [switch] $KeepStopped
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'bin'
$exe = Join-Path $bin 'winws.exe'
$lists = Join-Path $root 'lists'
$serviceName = 'zapret'
$registry = 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret'
. "$PSScriptRoot\service-state.ps1"
$installed = Get-ZapretService
if ($installed -and $Action -ne 'Start') {
    if (-not $installed.Executable) { throw 'Windows не вернула путь к службе Zapret. Проверь права доступа к службе.' }
    if (-not (Test-ZapretOwner $installed $root)) {
        if (-not (Test-ZapretManagedService $installed)) {
            throw 'Служба запущена из другой сборки Zapret. Удали её из меню той сборки.'
        }
        if ($Action -eq 'Repair') {
            throw 'Служба работает из прежней папки Zapret.'
        }
    }
}

if ($Action -eq 'Remove') {
    if ($installed) {
        if ($installed.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName
            Wait-ZapretService Stopped
        }
        $result = & "$env:SystemRoot\System32\sc.exe" delete $serviceName
        if ($LASTEXITCODE -ne 0) { throw ($result -join [Environment]::NewLine) }
        Write-Host 'Zapret service removed.'
    } else {
        Write-Host 'Zapret service is not installed.'
    }
    & "$PSScriptRoot\apex-auto.ps1" -Action Disable
    & "$PSScriptRoot\apex-maintenance.ps1" -Action Remove
    return
}

if ($Action -eq 'Start') {
    $blocker = Get-ZapretManualStartBlocker $installed
    if ($blocker) { throw $blocker }
}
if ($Action -eq 'Repair' -and $installed.Profile) { $Profile = $installed.Profile }
if ($Profile -eq 'Rust-Facepunch') { $Profile = 'Rust' }
if ($Profile -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,31}$') { throw 'Invalid installed profile name.' }

function Restore-RequiredLists {
    $defaults = @{
        'list-general-user.txt' = 'domain.example.abc'
        'list-exclude-user.txt' = 'domain.example.abc'
        'ipset-exclude-user.txt' = '203.0.113.113/32'
        'list-rust-maps-user.txt' = 'domain.example.abc'
    }
    foreach ($name in $defaults.Keys) {
        $path = Join-Path $lists $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
            [IO.File]::WriteAllLines($path, [string[]]@($defaults[$name]), [Text.Encoding]::ASCII)
            Write-Host "Восстановлен файл $name."
        }
    }

    if ($Profile -ne 'Apex') { return }

    $active = Join-Path $lists 'ipset-apex-sdr.txt'
    $fallback = Join-Path $PSScriptRoot 'apex-relays-default.txt'
    $valid = Test-Path -LiteralPath $active -PathType Leaf
    if ($valid) {
        $addresses = @([IO.File]::ReadAllLines($active) | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^#' })
        $valid = $addresses.Count -ge 20 -and $addresses.Count -le 4096
        foreach ($entry in $addresses) {
            $address = $null
            if (-not [Net.IPAddress]::TryParse($entry, [ref]$address) -or
                $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
                $valid = $false
                break
            }
        }
    }
    if (-not $valid) {
        [IO.File]::Copy($fallback, $active, $true)
        Write-Host 'Восстановлен список ретрансляторов Apex из архива.'
    }
}

Restore-RequiredLists
if ($Profile -eq 'Apex' -and $Action -in 'Start','Repair') {
    & "$PSScriptRoot\apex-maintenance.ps1" -Action Refresh
}
$template = Join-Path (Join-Path $root 'profiles') "$Profile.args"
if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { throw "Profile $Profile was not found." }
$options = [IO.File]::ReadAllText($template)
if ($Profile -eq 'Apex') {
    if ($Action -eq 'Install') {
        # Stop the session-only worker from v1.1.14 during an in-place upgrade.
        Remove-Item -LiteralPath (Join-Path $root '.runtime\apex-auto.enabled') -ErrorAction SilentlyContinue
    }
    $autoLists = & "$PSScriptRoot\apex-auto.ps1" -Action ListFolder
    $options = $options.Replace('%LISTS%ipset-apex-auto-',"$autoLists\ipset-apex-auto-")
}
$options = $options.Replace('%BIN%',"$bin\").Replace('%LISTS%',"$lists\")
$arguments = (($options -split '\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
$binaryPath = '"' + $exe + '" ' + $arguments
if ($arguments -notmatch '^--wf-' -or $binaryPath.Length -gt 30000) {
    throw 'The Winws profile is missing filter options or exceeds the command-line limit.'
}

if ($Action -eq 'Start') {
    $blocker = Get-ZapretManualStartBlocker (Get-ZapretService)
    if ($blocker) { throw $blocker }
    $process = Start-Process -FilePath $exe -WorkingDirectory $bin -ArgumentList $arguments -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw "Winws stopped with exit code $($process.ExitCode)." }
    return
}

$runtime = Join-Path $root '.runtime'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$check = Join-Path $runtime ('check-' + [guid]::NewGuid().ToString('N'))
$stdout = "$check.out"
$stderr = "$check.err"
try {
    # Winws saves the generated filter and exits before checking for another instance.
    $validationArgs = "$arguments --dry-run --wf-save=/dev/null"
    $validation = Start-Process -FilePath $exe -WorkingDirectory $bin -ArgumentList $validationArgs -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($validation.ExitCode -ne 0) {
        $detail = @(Get-Content -LiteralPath $stderr | Where-Object { $_.Trim() } | Select-Object -Last 3)
        if (-not $detail.Count) {
            $detail = @(Get-Content -LiteralPath $stdout | Where-Object { $_.Trim() } | Select-Object -Last 3)
        }
        throw ("Winws не принял профиль $Profile (код $($validation.ExitCode)). " + ($detail -join ' '))
    }
} finally {
    Remove-Item -LiteralPath $stdout,$stderr -ErrorAction SilentlyContinue
}

if ($Action -eq 'Repair' -and -not $installed) {
    Write-Host 'Profile checked. Use Install to enable the service.'
    return
}
function Sync-ApexHelper {
    & "$PSScriptRoot\apex-auto.ps1" -Action Sync
}

$startMode = if ($KeepStopped -and $installed.Start -ne 2) { 'Manual' } else { 'Automatic' }
$startValue = if ($startMode -eq 'Automatic') { 2 } else { 3 }
if ($installed -and $installed.Status -eq 'Running' -and $installed.Start -eq $startValue -and
    $installed.Command -ceq $binaryPath -and -not $KeepStopped) {
    Sync-ApexHelper
    Write-Host "Профиль $Profile уже запущен."
    return
}

$servicePid = 0
if ($installed -and $installed.Status -ne 'Stopped') {
    $servicePid = (Get-CimInstance Win32_Service -Filter "Name='zapret'" -ErrorAction SilentlyContinue).ProcessId
}
if (Get-Process -Name winws -ErrorAction SilentlyContinue | Where-Object Id -ne $servicePid) {
    throw 'Сначала закрой окно Zapret, запущенного вручную.'
}

$created = $false
$updated = $false
$wasRunning = $false
try {
    if ($installed) {
        $wasRunning = $installed.Status -ne 'Stopped'
        if ($wasRunning) {
            Stop-Service -Name $serviceName
            Wait-ZapretService Stopped
        }
        Set-ZapretServiceConfig $binaryPath $startValue
        $updated = $true
    } else {
        New-Service -Name $serviceName -BinaryPathName $binaryPath -DisplayName 'Zapret' -Description 'Local game profiles based on Flowseal' -StartupType $startMode | Out-Null
        $created = $true
    }
    if (-not $KeepStopped) {
        Start-Service -Name $serviceName
        Wait-ZapretService Running
    }
    New-ItemProperty -LiteralPath $registry -Name 'ZozickProfile' -Value $Profile -PropertyType String -Force | Out-Null
    Sync-ApexHelper
} catch {
    $failure = $_
    try {
        if ($created -or $updated) {
            Stop-Service -Name $serviceName
            Wait-ZapretService Stopped
        }
        if ($created) {
            & "$env:SystemRoot\System32\sc.exe" delete $serviceName | Out-Null
        } elseif ($updated) {
            Set-ZapretServiceConfig $installed.Command ([uint32]$installed.Start)
            if ($installed.Managed) {
                New-ItemProperty -LiteralPath $registry -Name 'ZozickProfile' -Value $installed.Profile -PropertyType String -Force | Out-Null
            }
        }
        if ($wasRunning) { Start-Service -Name $serviceName }
    } catch {
        Write-Warning "Could not restore the previous service state. $($_.Exception.Message)"
    }
    throw $failure
}

try {
    & "$PSScriptRoot\apex-maintenance.ps1" -Action Install
} catch {
    Write-Warning "The service is running. Could not register login updates. $($_.Exception.Message)"
}
Write-Host "Для службы Zapret выбран профиль $Profile."
