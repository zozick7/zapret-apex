param([ValidateSet('Status','Enable','Disable','ListFolder','Sync')][string]$Action)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$taskName = 'Zapret Apex Auto IP'
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$base = Join-Path $programFiles 'Zapret Apex'
$legacyDir = Join-Path $programFiles 'Zapret Game Profiles\Apex Auto'
$legacyWorker = Join-Path $legacyDir 'apex-auto-worker.ps1'
$legacyFlag = Join-Path $legacyDir 'apex-auto.enabled'
$workerDir = Join-Path $base 'Apex Auto'
$worker = Join-Path $workerDir 'apex-auto-worker.ps1'
$flag = Join-Path $workerDir 'apex-auto.enabled'
$ready = "$flag.ready"
$launchArgs = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
    $worker + '" -InstallRoot "' + $root + '"'
$legacyArgs = $launchArgs.Replace($worker,$legacyWorker)
. "$PSScriptRoot\service-state.ps1"

function Test-AutoEnabled {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    return ($task.Actions.Arguments -ceq $launchArgs) -and ($task.State -ne 'Disabled') -and
        (Test-Path -LiteralPath $flag -PathType Leaf)
}

function Test-LegacyEnabled {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    return ($task.Actions.Arguments -ceq $legacyArgs) -and ($task.State -ne 'Disabled') -and
        (Test-Path -LiteralPath $legacyFlag -PathType Leaf)
}

function Protect-ApexPath([string]$Path, [bool]$Directory) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Папка автоподбора Apex перенаправлена.' }
    $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $acl = if ($Directory) { [Security.AccessControl.DirectorySecurity]::new() }
        else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    $inheritance = if ($Directory) { 'ContainerInherit, ObjectInherit' } else { 'None' }
    foreach ($identity in $admins,$system) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity, 'FullControl', $inheritance, 'None', 'Allow'))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $users, 'ReadAndExecute', $inheritance, 'None', 'Allow'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Clear-ApexAutoLists {
    $path = Join-Path $workerDir 'ipset-apex-auto-match.txt'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $tmp = "$path.$([guid]::NewGuid().ToString('N'))"
        try {
            [IO.File]::WriteAllLines($tmp, [string[]]@('192.0.2.1'), [Text.Encoding]::ASCII)
            [IO.File]::Replace($tmp,$path,"$tmp.bak")
        } finally { Remove-Item -LiteralPath $tmp,"$tmp.bak" -ErrorAction SilentlyContinue }
    } else {
        [IO.File]::WriteAllLines($path, [string[]]@('192.0.2.1'), [Text.Encoding]::ASCII)
    }
}

function Stop-ApexAutoTask([switch]$KeepRegistered) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $arguments = [string]$task.Actions.Arguments
    $isLegacy = $arguments.Contains('-File "' + $legacyWorker + '" -InstallRoot "')
    if ($task -and -not $isLegacy -and -not $arguments.Contains('-File "' + $worker + '" -InstallRoot "')) {
        throw 'Имя задачи помощника Apex уже занято.'
    }
    $activeFlag = if ($isLegacy) { $legacyFlag } else { $flag }
    if (Test-Path -LiteralPath $activeFlag -PathType Leaf) { Remove-Item -LiteralPath $activeFlag }
    if (-not $task) { return }
    $deadline = [DateTime]::UtcNow.AddSeconds(6)
    while ($task.State -eq 'Running' -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    }
    if ($task.State -eq 'Running') {
        Stop-ScheduledTask -InputObject $task
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        do {
            Start-Sleep -Milliseconds 200
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        } while ($task.State -eq 'Running' -and [DateTime]::UtcNow -lt $deadline)
        if ($task.State -eq 'Running') { throw 'Автоподбор Apex ещё останавливается.' }
    }
    if ($task -and -not $KeepRegistered) { Unregister-ScheduledTask -InputObject $task -Confirm:$false }
}

function Start-ApexAutoWorker {
    Remove-Item -LiteralPath $ready -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path -LiteralPath $ready)) { throw 'Помощь Apex не запустилась.' }
}

function Sync-ApexAutoWorker {
    $source = Join-Path $PSScriptRoot 'apex-auto-worker.ps1'
    $target = Get-Item -LiteralPath $worker -Force
    if ($target.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Файл помощника Apex перенаправлен.' }
    $sourceState = Join-Path $PSScriptRoot 'service-state.ps1'
    $workerState = Join-Path $workerDir 'service-state.ps1'
    if ((Get-Item -LiteralPath $workerState -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Файл помощника Apex перенаправлен.'
    }
    if ((Get-FileHash -LiteralPath $source).Hash -eq (Get-FileHash -LiteralPath $worker).Hash -and
        (Get-FileHash -LiteralPath $sourceState).Hash -eq (Get-FileHash -LiteralPath $workerState).Hash) { return }
    $previous = [IO.File]::ReadAllBytes($worker)
    $previousState = [IO.File]::ReadAllBytes($workerState)
    Stop-ApexAutoTask -KeepRegistered
    try {
        Clear-ApexAutoLists
        [IO.File]::WriteAllBytes($worker, [IO.File]::ReadAllBytes($source))
        [IO.File]::WriteAllBytes($workerState, [IO.File]::ReadAllBytes($sourceState))
        New-Item -ItemType File -Path $flag -Force | Out-Null
        Start-ApexAutoWorker
    } catch {
        $failure = $_
        Stop-ApexAutoTask -KeepRegistered
        Clear-ApexAutoLists
        [IO.File]::WriteAllBytes($worker, $previous)
        [IO.File]::WriteAllBytes($workerState, $previousState)
        New-Item -ItemType File -Path $flag -Force | Out-Null
        Start-ApexAutoWorker
        throw $failure
    }
}

function Initialize-ApexHelper {
    foreach ($dir in $base,$workerDir) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Protect-ApexPath $dir $true
    }
    foreach ($name in 'apex-auto-worker.ps1','service-state.ps1') {
        $from = Join-Path $PSScriptRoot $name
        $to = Join-Path $workerDir $name
        if ((Test-Path -LiteralPath $to) -and ((Get-Item -LiteralPath $to -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Файл помощника Apex перенаправлен.'
        }
        Copy-Item -LiteralPath $from -Destination $to -Force
        Protect-ApexPath $to $false
    }
    Clear-ApexAutoLists
}

function Complete-ApexHelperMigration {
    $previousAction = (Get-ScheduledTask -TaskName $taskName).Actions
    try {
        Stop-ApexAutoTask -KeepRegistered
        $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $powershell -Argument $launchArgs
        Set-ScheduledTask -TaskName $taskName -Action $action | Out-Null
        New-Item -ItemType File -Path $flag -Force | Out-Null
        Start-ApexAutoWorker
    } catch {
        $failure = $_
        Stop-ApexAutoTask -KeepRegistered
        Set-ScheduledTask -TaskName $taskName -Action $previousAction | Out-Null
        New-Item -ItemType File -Path $legacyFlag -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        throw $failure
    }
}

switch ($Action) {
    'Sync' {
        if ((Test-LegacyEnabled) -and (Get-ZapretService).Command -like "*$workerDir\ipset-apex-auto-match.txt*") {
            Complete-ApexHelperMigration
        } elseif (Test-AutoEnabled) { Sync-ApexAutoWorker }
        return
    }
    'Status' { return ((Test-AutoEnabled) -or (Test-LegacyEnabled)) }
    'ListFolder' {
        if (Test-AutoEnabled) { return $workerDir }
        if (Test-LegacyEnabled) {
            Initialize-ApexHelper
            foreach ($name in 'apex-auto-decisions.log','apex-auto-decisions.log.old','apex-auto.log') {
                $from = Join-Path $legacyDir $name
                $to = Join-Path $workerDir $name
                if ((Test-Path -LiteralPath $from -PathType Leaf) -and -not (Test-Path -LiteralPath $to)) {
                    Copy-Item -LiteralPath $from -Destination $to
                }
            }
            return $workerDir
        }
        return (Join-Path $root 'lists')
    }
    'Disable' {
        if (Test-AutoEnabled) { Stop-ApexAutoTask; Clear-ApexAutoLists }
        elseif (Test-LegacyEnabled) { Stop-ApexAutoTask }
        return
    }
}

$service = Get-ZapretService
if ($service.Status -ne 'Running' -or $service.Profile -ne 'Apex' -or -not (Test-ZapretOwner $service $root)) {
    throw 'Сначала включи профиль Apex из этой папки.'
}
if (Test-AutoEnabled) { return }

Stop-ApexAutoTask
Initialize-ApexHelper
Remove-Item -LiteralPath $ready -ErrorAction SilentlyContinue
try {
    $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $taskAction = New-ScheduledTaskAction -Execute $powershell -Argument $launchArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
    $principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

    New-Item -ItemType File -Path $flag -Force | Out-Null
    & "$PSScriptRoot\profile-manager.ps1" -Action Install -Profile Apex
    Start-ApexAutoWorker
} catch {
    Stop-ApexAutoTask
    Clear-ApexAutoLists
    throw
}
