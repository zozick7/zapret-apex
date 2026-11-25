function Assert-ZapretProtectedDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    $reparse = [IO.FileAttributes]::ReparsePoint
    if (-not $item.PSIsContainer -or ($item.Attributes -band $reparse)) {
        throw 'Служебная папка Zapret перенаправлена.'
    }

    $trusted = 'S-1-5-18','S-1-5-32-544'
    $sidType = [Security.Principal.SecurityIdentifier]
    $acl = Get-Acl -LiteralPath $Path
    $write = [Security.AccessControl.FileSystemRights]'Write, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    if ($acl.GetOwner($sidType).Value -notin $trusted) {
        throw 'У служебной папки Zapret неверный владелец.'
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
        if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $write) -and
            $rule.IdentityReference.Value -notin $trusted) {
            throw 'Служебная папка Zapret доступна для записи без прав администратора.'
        }
    }
}

function New-ZapretProtectedDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
        $acl.SetOwner($admins)
        foreach ($identity in $admins,$system) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $users, 'ReadAndExecute', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        [void][IO.Directory]::CreateDirectory($Path, $acl)
    }
    Assert-ZapretProtectedDirectory $Path
}

function Remove-ZapretRuntime([string]$Path) {
    if (-not $Path) { return }
    $base = Get-ZapretProtectedRoot
    $prefix = [regex]::Escape($base)
    if ([IO.Path]::GetFullPath($Path) -notmatch "^$prefix\\service-[0-9a-f]{32}$") {
        throw 'Неверный путь к служебным файлам Zapret.'
    }
    Assert-ZapretProtectedDirectory $base
    Assert-ZapretProtectedDirectory $Path
    [IO.Directory]::Delete($Path, $true)
}

function Copy-ZapretRuntime([string]$Source, [string]$Target) {
    foreach ($name in 'bin','lists','utils') {
        New-Item -ItemType Directory -Path (Join-Path $Target $name) | Out-Null
    }
    $sourceBin = Join-Path $Source 'bin'
    $targetBin = Join-Path $Target 'bin'
    $manifest = Get-Content -LiteralPath (Join-Path $sourceBin 'hashes.json') -Raw | ConvertFrom-Json
    $required = 'winws.exe','WinDivert.dll','WinDivert64.sys','cygwin1.dll'
    foreach ($name in $required) {
        if ($manifest.PSObject.Properties.Name -notcontains $name) { throw "В архиве Zapret нет $name." }
    }
    foreach ($entry in $manifest.PSObject.Properties) {
        $name = $entry.Name
        if (($name -notin $required -and $name -notmatch '^[a-z0-9_][a-z0-9_.-]*\.bin$') -or
            $entry.Value -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'В архиве Zapret неверный список контрольных сумм.'
        }
        $targetFile = Join-Path $targetBin $name
        [IO.File]::Copy((Join-Path $sourceBin $name), $targetFile)
        if ((Get-FileHash -LiteralPath $targetFile).Hash -ine $entry.Value) {
            throw "Контрольная сумма $name не совпала. Скачай архив заново."
        }
    }

    Get-ChildItem -LiteralPath (Join-Path $Source 'lists') -File -Filter '*.txt' | ForEach-Object {
        [IO.File]::Copy($_.FullName, (Join-Path (Join-Path $Target 'lists') $_.Name))
    }
    foreach ($relative in 'release.json','utils\apex-maintenance.ps1','utils\updates.ps1',
        'utils\service-state.ps1','utils\service-storage.ps1') {
        [IO.File]::Copy((Join-Path $Source $relative), (Join-Path $Target $relative))
    }
}
