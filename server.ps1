param([int]$port = 8888)

$prefix = "http://localhost:$port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Output "HTTP server started on $prefix"

# Launch cloudflared tunnel
$cfLog = Join-Path (Get-Location) "cloudflared.log"
if (Test-Path $cfLog) { Remove-Item $cfLog -Force }

$cfProcess = Start-Process -FilePath (Join-Path (Get-Location) "cloudflared.exe") `
    -ArgumentList "tunnel --http-host-header localhost:$port --url http://localhost:$port" `
    -RedirectStandardError $cfLog `
    -NoNewWindow -PassThru

# Wait for tunnel URL in log
$onlineUrl = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $cfLog) {
        $logContent = Get-Content $cfLog -Raw
        if ($logContent -match "https://[a-zA-Z0-9-]+\.trycloudflare\.com") {
            $onlineUrl = $matches[0]
            break
        }
    }
}

if ($onlineUrl) {
    Set-Content -Path "online_url.txt" -Value $onlineUrl -Encoding UTF8
    Write-Output "ONLINE_URL: $onlineUrl"
}

# Serve requests safely
try {
    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response

            $rawUrl = $request.RawUrl
            $path = $rawUrl.Split('?')[0]
            if ($path -eq "/" -or $path -eq "") { $path = "/index.html" }
            $cleanName = [System.Uri]::UnescapeDataString($path).TrimStart('/')

            $filePath = Join-Path (Get-Location) $cleanName
            if (-not (Test-Path $filePath -PathType Leaf)) {
                # Fallback matcher
                if ($cleanName -match "_(\d+)\.jpg$") {
                    $found = Get-ChildItem -Filter "*_$($matches[1]).jpg" | Select-Object -First 1
                    if ($found) { $filePath = $found.FullName }
                } elseif ($cleanName -like "*xlsx") {
                    $found = Get-ChildItem -Filter "*สรุปการส่งงาน*.xlsx" | Select-Object -First 1
                    if ($found) { $filePath = $found.FullName }
                } elseif ($cleanName -like "*csv") {
                    $found = Get-ChildItem -Filter "*.csv" | Select-Object -First 1
                    if ($found) { $filePath = $found.FullName }
                }
            }

            if (Test-Path $filePath -PathType Leaf) {
                $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
                switch ($ext) {
                    ".html" { $response.ContentType = "text/html; charset=utf-8" }
                    ".jpg"  { $response.ContentType = "image/jpeg" }
                    ".jpeg" { $response.ContentType = "image/jpeg" }
                    ".png"  { $response.ContentType = "image/png" }
                    ".json" { $response.ContentType = "application/json; charset=utf-8" }
                    ".xlsx" { $response.ContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }
                    ".csv"  { $response.ContentType = "text/csv; charset=utf-8" }
                    default { $response.ContentType = "application/octet-stream" }
                }
                $bytes = [System.IO.File]::ReadAllBytes($filePath)
                $response.ContentLength64 = $bytes.Length
                if ($request.HttpMethod -ne "HEAD") {
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
            } else {
                $response.StatusCode = 404
                $msg = [System.Text.Encoding]::UTF8.GetBytes("Not Found")
                $response.ContentLength64 = $msg.Length
                if ($request.HttpMethod -ne "HEAD") {
                    $response.OutputStream.Write($msg, 0, $msg.Length)
                }
            }
            $response.Close()
        } catch {
            # Catch transient error and keep listening
        }
    }
} finally {
    $listener.Stop()
    if ($cfProcess -and -not $cfProcess.HasExited) {
        Stop-Process -Id $cfProcess.Id -Force
    }
}
