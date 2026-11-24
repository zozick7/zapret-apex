param(
    [string]$Profile,
    [switch]$RemoveRepair
)

$ErrorActionPreference = 'Stop'
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$proxyImage = '/external/E61lHGLVt4b1Izdu7X0KJRGmYDpyFMvs9buCRCdKcxY/https/cdn.discordapp.com/embed/avatars/5.png'
$media = [ordered]@{
    'media.discordapp.net' = '/stickers/781291131828699156.png?size=160'
    'cdn.discordapp.com' = '/embed/avatars/0.png'
    'images-ext-1.discordapp.net' = $proxyImage
    'images-ext-2.discordapp.net' = $proxyImage
}
$mediaPattern = '(' + (($media.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'
$managed = '(?im)^[ \t]*\d{1,3}(?:\.\d{1,3}){3}[ \t]+' + $mediaPattern + '[ \t]+# Zapret (?:Discord|local Discord media)[ \t]*(?:\r?\n|$)'
$encoding = [Text.Encoding]::GetEncoding(28591)
$dnsCache = @{}
$connectionOptions = @('--noproxy','*')
$interfaceName = $null

function Select-DirectConnection {
    $route = Find-NetRoute -RemoteIPAddress '8.8.8.8' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DestinationPrefix'] } | Select-Object -First 1
    $physical = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    if (-not $route -or -not $physical.Count -or $route.InterfaceIndex -in $physical.InterfaceIndex) { return }
    $connection = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceIndex -in $physical.InterfaceIndex -and $_.IPv4Address -and
            ($_.IPv4DefaultGateway | Where-Object NextHop -ne '0.0.0.0')
    } | Sort-Object { $_.NetIPv4Interface.InterfaceMetric } | Select-Object -First 1
    if ($connection) {
        $script:connectionOptions += @('--interface', $connection.IPv4Address[0].IPAddress)
        $script:interfaceName = $connection.InterfaceAlias
    }
}

function Test-Endpoint([string]$Url, [string]$Address, [switch]$Image, [switch]$HostOnly) {
    $options = $connectionOptions + @('--silent','--connect-timeout','2','--max-time','4',
        '--max-filesize','4000000','--output','NUL','--write-out','%{http_code} %{size_download} %{content_type}')
    if ($Address) { $options += @('--resolve', (([uri]$Url).DnsSafeHost + ':443:' + $Address)) }
    $response = & $curl @options $Url
    if ($LASTEXITCODE -ne 0) { return $false }
    if ($Image) { return $response -match '^200 [1-9]\d* image/' }
    if ($HostOnly) { return $response -match '^[234]\d{2} ' }
    return $response -match '^2\d{2} [1-9]\d* '
}

function Get-PublicIPv4([string]$Domain) {
    if ($dnsCache.ContainsKey($Domain)) { return $dnsCache[$Domain] }
    foreach ($resolver in @(
        @{ Name='dns.google'; IP='8.8.8.8'; Api='/resolve' },
        @{ Name='cloudflare-dns.com'; IP='1.1.1.1'; Api='/dns-query' }
    )) {
        $url = "https://$($resolver.Name)$($resolver.Api)?type=A&name=$Domain"
        $pin = $resolver.Name + ':443:' + $resolver.IP
        $json = & $curl @connectionOptions --silent --fail --connect-timeout 2 --max-time 4 --max-filesize 65536 --resolve $pin -H 'Accept: application/dns-json' $url
        if ($LASTEXITCODE -ne 0 -or -not $json) { continue }
        try { $response = ($json -join [Environment]::NewLine) | ConvertFrom-Json }
        catch { continue }
        $addresses = @($response.Answer | Where-Object { $_.type -eq 1 -and $_.data -match '^\d{1,3}(?:\.\d{1,3}){3}$' } |
            Select-Object -ExpandProperty data -Unique)
        if ($addresses.Count) {
            $dnsCache[$Domain] = $addresses
            return $addresses
        }
    }
    $addresses = @(Resolve-DnsName -Name $Domain -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction SilentlyContinue |
        Where-Object Type -eq 'A' | Select-Object -ExpandProperty IPAddress -Unique)
    $dnsCache[$Domain] = $addresses
    return $addresses
}

function Write-Hosts([string]$Expected, [string]$Contents) {
    if ($Contents -ceq $Expected) { return }
    $temporary = "$hostsPath.zapret-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporary, $encoding.GetBytes($Contents))
        if ($encoding.GetString([IO.File]::ReadAllBytes($hostsPath)) -cne $Expected) {
            throw 'Файл hosts изменился во время проверки. Запусти проверку сети ещё раз.'
        }
        [IO.File]::Replace($temporary, $hostsPath, [NullString]::Value)
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    } finally {
        Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue
    }
}

function Repair-DiscordMedia {
    $current = $encoding.GetString([IO.File]::ReadAllBytes($hostsPath))
    $repaired = 0
    $failed = 0
    $userLines = [regex]::Replace($current, $managed, '') -split '\r?\n'
    $fallback = @('162.159.138.232','162.159.137.232','162.159.128.233','162.159.135.232')
    foreach ($domain in $media.Keys) {
        $url = "https://$domain$($media[$domain])"
        if (Test-Endpoint $url -Image) { continue }
        $custom = $userLines | Where-Object {
            $fields = ($_ -split '#',2)[0].Trim() -split '\s+'
            $fields.Count -ge 2 -and $domain -in $fields[1..($fields.Count - 1)]
        } | Select-Object -First 1
        if ($custom -or $interfaceName) { $failed++; continue }

        $working = $fallback | Where-Object { Test-Endpoint $url $_ -Image } |
            Select-Object -First 1
        if (-not $working) {
            $candidates = @(Get-PublicIPv4 $domain | Select-Object -First 3)
            $candidates += @(Get-PublicIPv4 'discord.com' | Select-Object -First 5)
            $candidates += @(Get-PublicIPv4 'cdn.discordapp.com' | Select-Object -First 3)
            $working = $candidates | Where-Object { $_ -notin $fallback } |
                Select-Object -Unique -First 8 | Where-Object { Test-Endpoint $url $_ -Image } |
                Select-Object -First 1
        }
        if (-not $working) { $failed++; continue }

        $domainPattern = $managed.Replace($mediaPattern, [regex]::Escape($domain))
        $proposed = [regex]::Replace($current, $domainPattern, '')
        if ($proposed -and -not $proposed.EndsWith([string][char]10)) { $proposed += [Environment]::NewLine }
        $proposed += "$working  $domain  # Zapret Discord" + [Environment]::NewLine
        Write-Hosts $current $proposed
        if (Test-Endpoint $url -Image) {
            $current = $proposed
            $repaired++
        } else {
            Write-Hosts $proposed $current
            $failed++
        }
    }
    if ($repaired) { Write-Host 'Подобраны рабочие адреса для картинок Discord. Если картинки всё ещё не грузятся, нажми Ctrl+R в Discord.' }
    if ($failed -and $interfaceName) { Write-Warning 'Discord: отключи VPN и повтори проверку.' }
    elseif ($failed) { Write-Warning 'Discord: часть картинок недоступна.' }
    elseif (-not $repaired) { Write-Host 'Discord: тестовые картинки загрузились.' }
}

if ($RemoveRepair) {
    $original = $encoding.GetString([IO.File]::ReadAllBytes($hostsPath))
    Write-Hosts $original ([regex]::Replace($original, $managed, ''))
    return
}
if (-not (Test-Path -LiteralPath $curl -PathType Leaf)) { throw 'Для проверки сети нужен curl.exe из Windows.' }

Select-DirectConnection
if ($interfaceName) { Write-Warning "Чтобы проверить доступ через Zapret, отключи VPN и повтори проверку." }
else { Write-Host 'Проверка сети…' }
try { Repair-DiscordMedia }
catch { Write-Warning "Discord: $($_.Exception.Message)" }
if (Test-Endpoint 'https://discord.com/api/v10/gateway') { Write-Host 'Discord: API доступен.' }
else { Write-Warning 'Discord: API недоступен.' }

$youTube = 'https://www.youtube.com/watch?v=jNQXAC9IVRw'
if (Test-Endpoint $youTube) {
    if (Test-Endpoint 'https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg' -Image) {
        Write-Host 'YouTube: страница и миниатюры доступны.'
    } else {
        Write-Warning 'YouTube: страница открывается, миниатюра недоступна.'
    }
} else {
    $reachable = Get-PublicIPv4 'www.youtube.com' | Select-Object -First 3 |
        Where-Object { Test-Endpoint $youTube $_ } | Select-Object -First 1
    if ($reachable) { Write-Warning 'Страница YouTube открылась с другим DNS.' }
    else { Write-Warning 'YouTube: страница недоступна.' }
}
if ($Profile -eq 'Rust') {
    $official = Test-Endpoint 'https://files.facepunch.com/' -HostOnly
    $community = Test-Endpoint 'https://maps.rustmaps.com/' -HostOnly
    if ($official -and $community) { Write-Host 'Серверы карт Rust доступны.' }
    else { Write-Warning 'Один или оба сервера карт Rust недоступны.' }
}
