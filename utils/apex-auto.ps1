param([ValidateSet('Status','Enable','Disable','ListFolder')][string]$Action)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$taskName = 'Zapret Apex Auto IP'
$base = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Zapret Game Profiles'
$workerDir = Join-Path $base 'Apex Auto'
$worker = Join-Path $workerDir 'apex-auto-worker.ps1'
$flag = Join-Path $workerDir 'apex-auto.enabled'
$ready = "$flag.ready"
$launchArgs = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
    $worker + '" -InstallRoot "' + $root + '"'
. "$PSScriptRoot\service-state.ps1"

function Test-AutoEnabled {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    return ($task.Actions.Arguments -ceq $launchArgs) -and ($task.State -ne 'Disabled') -and
        (Test-Path -LiteralPath $flag -PathType Leaf)
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
    foreach ($name in 'ipset-apex-auto-game.txt','ipset-apex-auto-sdr.txt') {
        $path = Join-Path $workerDir $name
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
}

function Stop-ApexAutoTask {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task -and -not $task.Actions.Arguments.Contains('-File "' + $worker + '" -InstallRoot "')) {
        throw 'Имя задачи автоподбора Apex уже занято.'
    }
    if (Test-Path -LiteralPath $flag -PathType Leaf) { Remove-Item -LiteralPath $flag }
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
    if ($task) { Unregister-ScheduledTask -InputObject $task -Confirm:$false }
}

switch ($Action) {
    'Status' { return (Test-AutoEnabled) }
    'ListFolder' {
        if (Test-AutoEnabled) { return $workerDir }
        return (Join-Path $root 'lists')
    }
    'Disable' {
        if (Test-AutoEnabled) { Stop-ApexAutoTask; Clear-ApexAutoLists }
        return
    }
}

$service = Get-ZapretService
if ($service.Status -ne 'Running' -or $service.Profile -ne 'Apex' -or -not (Test-ZapretOwner $service $root)) {
    throw 'Сначала включи профиль Apex из этой папки.'
}
if (Test-AutoEnabled) { return }

foreach ($dir in $base,$workerDir) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Protect-ApexPath $dir $true
}
Stop-ApexAutoTask
foreach ($name in 'apex-auto-worker.ps1','apex-udp-capture.ps1','service-state.ps1','WinDivert.dll') {
    $from = if ($name -eq 'WinDivert.dll') { Join-Path $root "bin\$name" } else { Join-Path $PSScriptRoot $name }
    $to = Join-Path $workerDir $name
    if ((Test-Path -LiteralPath $to) -and ((Get-Item -LiteralPath $to -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Файл автоподбора Apex перенаправлен.'
    }
    Copy-Item -LiteralPath $from -Destination $to -Force
    Protect-ApexPath $to $false
}
Clear-ApexAutoLists
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
    Start-ScheduledTask -TaskName $taskName
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path -LiteralPath $ready)) { throw 'Автоподбор Apex не запустился.' }
} catch {
    Stop-ApexAutoTask
    Clear-ApexAutoLists
    throw
}
