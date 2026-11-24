$ErrorActionPreference = 'Stop'
$text = ([string](Read-Host 'Вставь ссылку на карту из консоли F1 (Enter для возврата)')).Trim()
if (-not $text) { return }

$uri = $null
if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -notin 'http','https' -or $uri.UserInfo) {
    throw 'Нужен HTTP- или HTTPS-адрес карты.'
}

Write-Host "Сервер карты $($uri.DnsSafeHost)"
$request = [Net.HttpWebRequest][Net.WebRequest]::Create($uri)
$request.Method = 'GET'
$request.AddRange(0, 65535)
$request.Timeout = 12000
$request.ReadWriteTimeout = 6000
$request.MaximumAutomaticRedirections = 5

$response = $null
$stream = $null
try {
    $response = $request.GetResponse()
    $stream = $response.GetResponseStream()
    $buffer = [byte[]]::new(8192)
    $total = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($total -lt 65536 -and $timer.Elapsed.TotalSeconds -lt 12) {
        $count = $stream.Read($buffer, 0, [Math]::Min($buffer.Length,65536-$total))
        if ($count -eq 0) { break }
        $total += $count
    }
    if ($response.ResponseUri.DnsSafeHost -ne $uri.DnsSafeHost) {
        Write-Host "Ссылка ведёт на сервер $($response.ResponseUri.DnsSafeHost)"
    }
    Write-Host "HTTP $([int]$response.StatusCode), получено $total байт."
    if ($response.ContentType -match '^text/html') {
        Write-Warning 'По ссылке открылась веб-страница. Нужна прямая ссылка на файл карты.'
    } elseif ($total -ge 65536 -or
        ($response.ContentLength -gt 0 -and $total -eq $response.ContentLength)) {
        Write-Host 'Загрузка файла началась. Полную загрузку проверь в Rust.'
    } else {
        Write-Warning 'Скачалась только часть файла. Проверь ссылку в браузере.'
    }
} catch [Net.WebException] {
    if ($_.Exception.Response) {
        $failure = $_.Exception.Response
        try { Write-Warning "Сервер ответил кодом HTTP $([int]$failure.StatusCode)." }
        finally { $failure.Dispose() }
    } else {
        Write-Warning "Скачать карту не удалось. Ошибка Windows $($_.Exception.Status)."
    }
} finally {
    if ($stream) { $stream.Dispose() }
    if ($response) { $response.Dispose() }
    $request.Abort()
}