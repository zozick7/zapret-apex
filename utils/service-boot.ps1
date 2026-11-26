$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$config = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' -ErrorAction SilentlyContinue
if ($config.ZozickBootManaged -ne 1 -or $config.Start -ne 3) { return }
if ((Get-Service -Name zapret).Status -ne 'Stopped') { return }

$list = Join-Path (Split-Path -Parent $PSScriptRoot) 'Apex Auto\ipset-apex-auto-match.txt'
if ($config.ZozickProfile -eq 'Apex' -and $config.ImagePath.Contains('"' + $list + '"')) {
    $pending = "$list.$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllLines($pending, [string[]]@('192.0.2.1'), [Text.Encoding]::ASCII)
        if ([IO.File]::Exists($list)) { [IO.File]::Replace($pending, $list, "$pending.bak") }
        else { [IO.File]::Move($pending, $list) }
    } finally {
        Remove-Item -LiteralPath $pending,"$pending.bak" -ErrorAction SilentlyContinue
    }
}
Start-Service -Name zapret
