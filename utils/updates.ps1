param([switch]$Quiet, [switch]$Install)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Get-Content -LiteralPath (Join-Path $root 'release.json') -Raw | ConvertFrom-Json
$repository = $build.repository
if ($repository -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$') { throw 'В настройках указан неверный адрес репозитория GitHub.' }
$current = [version]$build.version
$headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Zapret-Apex' }
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest" -Headers $headers -TimeoutSec 10
$tag = [string]$release.tag_name
if ($tag -notmatch '^v(\d+\.\d+\.\d+)$' -or $release.draft -or $release.prerelease) {
    throw 'GitHub вернул релиз с неподходящей версией или статусом.'
}
if ([version]$Matches[1] -le $current) {
    if (-not $Quiet) { Write-Host "Установлена последняя версия ($current)." }
    return
}

$assetName = 'zapret-apex.zip'
$asset = @($release.assets | Where-Object name -ceq $assetName)
$expectedUrl = "https://github.com/$repository/releases/download/$tag/$assetName"
if ($asset.Count -ne 1 -or $asset[0].browser_download_url -ine $expectedUrl -or
    $asset[0].state -ne 'uploaded' -or $asset[0].size -lt 1 -or $asset[0].size -gt 25MB -or
    $asset[0].digest -notmatch '^sha256:([0-9a-f]{64})$') {
    throw 'Не удалось проверить архив обновления на GitHub.'
}
$expectedHash = $Matches[1]
. "$PSScriptRoot\service-state.ps1"
. "$PSScriptRoot\service-storage.ps1"
$protected = Get-ZapretProtectedRoot
New-ZapretProtectedDirectory $protected
$updates = Join-Path $protected 'Updates'
New-ZapretProtectedDirectory $updates
$folder = Join-Path $updates $tag
$zip = Join-Path $folder $assetName
New-ZapretProtectedDirectory $folder
if (-not (Test-Path -LiteralPath $zip -PathType Leaf) -or
    (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ine $expectedHash) {
    $temp = "$zip.$([guid]::NewGuid().ToString('N')).part"
    try {
        Invoke-WebRequest -Uri $expectedUrl -UseBasicParsing -OutFile $temp -TimeoutSec 30
        if ((Get-Item -LiteralPath $temp).Length -ne $asset[0].size -or
            (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ine $expectedHash) {
            throw 'Контрольная сумма скачанного архива не совпала.'
        }
        Move-Item -LiteralPath $temp -Destination $zip -Force
    } finally {
        Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
    }
}
$summary = [string](([string]$release.body -split '\r?\n' |
    Where-Object { $_.Trim() } | Select-Object -First 1))
$summary = ($summary -replace '^\s*(?:#{1,6}|[-*+])\s+', '' -replace '[\p{C}\p{Zl}\p{Zp}]+', ' ').Trim()
if ($summary.Length -gt 160) { $summary = $summary.Substring(0,159).TrimEnd() + '…' }
Set-Content -LiteralPath (Join-Path $folder 'release-summary.txt') -Value $summary -Encoding UTF8
Set-Content -LiteralPath (Join-Path $updates 'ready-version.txt') -Value $tag -Encoding ASCII
if ($Install) {
    . "$PSScriptRoot\install-update.ps1"
    return (Install-ZapretUpdate $zip $tag)
}
if (-not $Quiet) {
    Write-Host "Архив $tag скачан и проверен."
    Write-Host $zip
}