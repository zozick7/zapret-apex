function Install-ZapretUpdate([string]$Archive, [string]$Tag) {
    . "$PSScriptRoot\service-state.ps1"
    $service = Get-ZapretService
    if ($service -and -not (Test-ZapretOwner $service $root)) {
        throw 'Служба Zapret работает из другой папки. Открой меню в той папке и обнови оттуда.'
    }
    $wasRunning = $service -and $service.Status -eq 'Running'
    $servicePid = 0
    if ($wasRunning) { $servicePid = (Get-CimInstance Win32_Service -Filter "Name='zapret'").ProcessId }
    if (Get-Process -Name winws -ErrorAction SilentlyContinue | Where-Object Id -ne $servicePid) {
        throw 'Сначала закрой окно Zapret, запущенного вручную.'
    }

    . "$PSScriptRoot\service-storage.ps1"
    $protected = Get-ZapretProtectedRoot
    New-ZapretProtectedDirectory $protected
    $data = Join-Path $protected 'Updates'
    New-ZapretProtectedDirectory $data
    $lock = [IO.File]::Open((Join-Path $data 'update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $installed = Get-Content -LiteralPath (Join-Path $root 'release.json') -Raw | ConvertFrom-Json
        if ([version]$Tag.Substring(1) -le [version]$installed.version) { return $false }
        $stage = Join-Path $data ('update-' + [guid]::NewGuid().ToString('N'))
        $backup = Join-Path $stage 'backup'
        $changed = New-Object 'System.Collections.Generic.List[object]'
        $archivePrefix = 'Zapret-Apex/'
        $planned = New-Object 'System.Collections.Generic.List[string]'
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipFile = [IO.Compression.ZipFile]::OpenRead($Archive)
        try {
            $total = 0L
            foreach ($entry in $zipFile.Entries) {
                if (-not $entry.Name) { continue }
                $name = $entry.FullName.Replace('\','/')
                if (-not $name.StartsWith($archivePrefix, [StringComparison]::Ordinal)) {
                    throw 'Unexpected directory in the release archive.'
                }
                $relative = $name.Substring($archivePrefix.Length)
                if ($relative -notmatch '^(?:service\.bat|release\.json|README\.md|LICENSE\.txt|(?:bin|profiles|lists|utils)/[a-z0-9][a-z0-9_. -]*)$' -or
                    -not $seen.Add($relative)) {
                    throw 'Unexpected or duplicated file in the release archive.'
                }
                $total += $entry.Length
                if ($total -gt 30MB) { throw 'The release archive is too large.' }
                $planned.Add($relative)
            }
        } finally { $zipFile.Dispose() }

        foreach ($required in 'service.bat','release.json','bin/winws.exe','utils/menu.ps1',
            'utils/profile-manager.ps1','utils/service-state.ps1','utils/service-storage.ps1',
            'bin/hashes.json','profiles/Apex.args') {
            if ($required -notin $planned) { throw "Release file missing: $required" }
        }
        New-ZapretProtectedDirectory $stage
        Expand-Archive -LiteralPath $Archive -DestinationPath $stage
        $source = Join-Path $stage 'Zapret-Apex'
        $manifest = Get-Content -LiteralPath (Join-Path $source 'release.json') -Raw | ConvertFrom-Json
        if ($manifest.repository -cne $repository -or "v$($manifest.version)" -cne $Tag) {
            throw 'Release version or repository does not match.'
        }

        $profile = 'Apex'
        if ($service.Profile) { $profile = $service.Profile }
        try {
            if ($wasRunning) {
                Stop-Service -Name zapret
                Wait-ZapretService Stopped
            }
            foreach ($relative in ($planned | Sort-Object { $_ -eq 'release.json' })) {
                $from = Join-Path $source $relative
                $to = Join-Path $root $relative
                $exists = Test-Path -LiteralPath $to -PathType Leaf
                if ($exists -and ($relative -like 'lists/*-user.txt' -or
                    (Get-FileHash -LiteralPath $from).Hash -eq (Get-FileHash -LiteralPath $to).Hash)) {
                    continue
                }
                $previous = Join-Path $backup $relative
                if ($exists) {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $previous) -Force | Out-Null
                    Copy-Item -LiteralPath $to -Destination $previous
                }
                $changed.Add([pscustomobject]@{ Path=$to; Backup=$previous; Existed=$exists })
                Copy-Item -LiteralPath $from -Destination $to -Force
            }
            if ($service) {
                & "$PSScriptRoot\profile-manager.ps1" -Action Install -Profile $profile -KeepStopped:(-not $wasRunning)
            }
        } catch {
            $failure = $_
            foreach ($file in $changed) {
                if ($file.Existed) { Copy-Item -LiteralPath $file.Backup -Destination $file.Path -Force }
                elseif (Test-Path -LiteralPath $file.Path) { Remove-Item -LiteralPath $file.Path }
            }
            if ($wasRunning -and (Get-ZapretService).Status -ne 'Running') { Start-Service -Name zapret }
            throw $failure
        }
        try { Clear-OldZapretBackups }
        catch { Write-Warning "Не удалось очистить старые копии обновлений. $($_.Exception.Message)" }
        Write-Host "Установлена версия $Tag. Копия прежних файлов хранится в $backup"
        return $true
    } finally { $lock.Dispose() }
}
