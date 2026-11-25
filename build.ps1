param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$UpstreamArchive,
    [string]$WorkDirectory = [IO.Path]::GetTempPath()
)

$ErrorActionPreference = 'Stop'
$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'release.json') -Raw | ConvertFrom-Json).version
if ($env:GITHUB_REF_TYPE -eq 'tag' -and $env:GITHUB_REF_NAME -cne "v$version") {
    throw "Tag must match release.json (v$version)."
}
foreach ($script in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'utils') -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
}

$downloadUrl = 'https://github.com/Flowseal/zapret-discord-youtube/releases/download/1.10.4/zapret-discord-youtube-1.10.4.zip'
$upstreamHash = '291af673bd0238506f9548e0e94ca0abf244000f4c9a06960544fb01c5f97b34'
$scratch = Join-Path $WorkDirectory ('zapret-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

if (-not $UpstreamArchive) {
    $UpstreamArchive = Join-Path $scratch 'upstream.zip'
    Invoke-WebRequest -Uri $downloadUrl -OutFile $UpstreamArchive -UseBasicParsing -TimeoutSec 60
}
if ((Get-FileHash -LiteralPath $UpstreamArchive -Algorithm SHA256).Hash -ine $upstreamHash) {
    throw 'The Flowseal ZIP did not match the pinned SHA-256 hash.'
}
$base = Join-Path $scratch 'upstream'
Expand-Archive -LiteralPath $UpstreamArchive -DestinationPath $base
$base = Join-Path $base 'zapret-discord-youtube-1.10.4'
$stage = Join-Path $scratch 'Zapret-Apex'
New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
foreach ($file in 'service.bat','release.json','README.md','LICENSE.txt') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $stage
}
foreach ($dir in 'profiles','utils','lists') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $dir) -Destination $stage -Recurse
}

$packages = 'winws.exe','WinDivert.dll','WinDivert64.sys','cygwin1.dll'
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $stage 'profiles') -Filter '*.args') {
    $contents = [IO.File]::ReadAllText($file.FullName)
    foreach ($match in [regex]::Matches($contents, '%BIN%([A-Za-z0-9_.-]+)')) { $packages += $match.Groups[1].Value }
    foreach ($match in [regex]::Matches($contents, '%LISTS%([A-Za-z0-9_.-]+)')) {
        $name = $match.Groups[1].Value
        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $stage 'lists') $name) -PathType Leaf) -and
            $name -notin @('list-general-user.txt','list-exclude-user.txt','ipset-exclude-user.txt','ipset-apex-sdr.txt')) {
            throw "Missing $name referenced by $($file.Name)."
        }
    }
}
foreach ($file in $packages | Sort-Object -Unique) {
    Copy-Item -LiteralPath (Join-Path (Join-Path $base 'bin') $file) -Destination (Join-Path $stage 'bin')
}

$bin = Join-Path $stage 'bin'
$hashes = [ordered]@{}
foreach ($name in $packages | Sort-Object -Unique) {
    $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $bin $name) -Algorithm SHA256).Hash
}
$hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bin 'hashes.json') -Encoding ASCII

# Compare the bundled engine with bol-van's published x64 checksum.
$winwsHash = 'affb4f69d2ea302a7abccd5325d81826e140ddae014f1e070bc4a6c0dd555188'
$winws = Join-Path $stage 'bin\winws.exe'
if ((Get-FileHash -LiteralPath $winws -Algorithm SHA256).Hash -ine $winwsHash) {
    throw 'winws.exe did not match the official Zapret v72.9 x64 checksum.'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory 'zapret-apex.zip'
Compress-Archive -LiteralPath $stage -DestinationPath $output -Force
$checksum = Get-FileHash -LiteralPath $output -Algorithm SHA256
Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Value "$($checksum.Hash.ToLowerInvariant())  zapret-apex.zip" -Encoding ASCII
$checksum
