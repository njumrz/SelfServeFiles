<#
.SYNOPSIS
Validates TVBox-related links by simulating the network request style used by TVBox/OkHttp.

.DESCRIPTION
This script reads tvbox-lines.json, requests every entry in urls and lives, and reports whether
the URL is reachable at the network layer. It intentionally does not parse TVBox JSON, image-disguised
interfaces, M3U playlists, or other response payloads.

The request simulation uses:
- GET requests
- OkHttp-like User-Agent
- Accept: */*
- automatic redirects
- gzip/deflate decompression
- IDN/punycode conversion for non-ASCII host names

.PARAMETER Path
Path to tvbox-lines.json.

.PARAMETER TimeoutSeconds
Request timeout per URL.

.PARAMETER FailOnUnavailable
Exit with code 1 when one or more URLs cannot be fetched successfully.

.PARAMETER AsJson
Print the validation result objects as JSON instead of a table.

.PARAMETER ResultsDirectory
Directory where the HTML validation report will be saved.

.PARAMETER NoHtml
Skip writing the HTML validation report.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Path = (Join-Path $PSScriptRoot '..\tvbox-lines.json'),

    [Parameter()]
    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 10,

    [Parameter()]
    [switch]$FailOnUnavailable,

    [Parameter()]
    [switch]$AsJson,

    [Parameter()]
    [string]$ResultsDirectory = (Join-Path $PSScriptRoot '..\validate-results'),

    [Parameter()]
    [switch]$NoHtml
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function ConvertTo-IdnUrl {
    param([Parameter(Mandatory)][string]$Url)

    try {
        $uri = [System.Uri]$Url
        if ($uri.Host -match '[^\x00-\x7F]') {
            $idn = [System.Globalization.IdnMapping]::new()
            $builder = [System.UriBuilder]::new($uri)
            $builder.Host = $idn.GetAscii($uri.Host)
            return $builder.Uri.AbsoluteUri
        }
    }
    catch {
        # Return the original URL and let the request surface the failure.
    }

    return $Url
}

function Invoke-TvBoxLikeFetch {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $actualUrl = ConvertTo-IdnUrl -Url $Url

    try {
        $request = [System.Net.HttpWebRequest]::Create($actualUrl)
        $request.Method = 'GET'
        $request.UserAgent = 'okhttp/4.12.0'
        $request.Accept = '*/*'
        $request.AllowAutoRedirect = $true
        $request.MaximumAutomaticRedirections = 5
        $request.Timeout = $TimeoutMilliseconds
        $request.ReadWriteTimeout = $TimeoutMilliseconds
        $request.KeepAlive = $true
        $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        try {
            $stream = $response.GetResponseStream()
            $buffer = [byte[]]::new(8192)
            $bytes = 0L

            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $bytes += $read
            }

            return [pscustomobject]@{
                Ok          = ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400)
                Status      = [int]$response.StatusCode
                Bytes       = $bytes
                ContentType = $response.ContentType
                FinalUrl    = $response.ResponseUri.AbsoluteUri
                Error       = ''
            }
        }
        finally {
            $response.Close()
        }
    }
    catch [System.Net.WebException] {
        $status = $null
        $contentType = ''
        $finalUrl = $actualUrl

        if ($_.Exception.Response) {
            $errorResponse = [System.Net.HttpWebResponse]$_.Exception.Response
            $status = [int]$errorResponse.StatusCode
            $contentType = $errorResponse.ContentType
            $finalUrl = $errorResponse.ResponseUri.AbsoluteUri
            $errorResponse.Close()
        }

        return [pscustomobject]@{
            Ok          = $false
            Status      = $status
            Bytes       = 0L
            ContentType = $contentType
            FinalUrl    = $finalUrl
            Error       = $_.Exception.Message
        }
    }
    catch {
        return [pscustomobject]@{
            Ok          = $false
            Status      = $null
            Bytes       = 0L
            ContentType = ''
            FinalUrl    = $actualUrl
            Error       = $_.Exception.Message
        }
    }
}

function New-HtmlReport {
        param(
                [Parameter(Mandatory)][object[]]$Results,
                [Parameter(Mandatory)][string]$ConfigPath,
                [Parameter(Mandatory)][string]$OutputDirectory
        )

        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
                New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        }

        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $reportPath = Join-Path $OutputDirectory "validate-tvbox-links-$timestamp.html"
        $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
        $okCount = @($Results | Where-Object { $_.Ok }).Count
        $failedCount = @($Results | Where-Object { -not $_.Ok }).Count

        $style = @'
body { font-family: "Segoe UI", Arial, sans-serif; margin: 24px; color: #1f2328; }
h1 { margin-bottom: 4px; }
.meta { color: #57606a; margin-bottom: 16px; }
.summary { display: flex; gap: 12px; margin: 16px 0 24px; }
.card { border: 1px solid #d0d7de; border-radius: 8px; padding: 12px 16px; min-width: 120px; background: #f6f8fa; }
.card strong { display: block; font-size: 24px; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #d0d7de; padding: 8px; vertical-align: top; }
th { background: #f6f8fa; text-align: left; }
tr.ok { background: #dafbe1; }
tr.failed { background: #ffebe9; }
td.url { word-break: break-all; }
'@

        $rows = foreach ($result in $Results) {
                $class = if ($result.Ok) { 'ok' } else { 'failed' }
                $status = if ($null -eq $result.Status) { '' } else { [System.Net.WebUtility]::HtmlEncode([string]$result.Status) }
                @"
<tr class="$class">
    <td>$([System.Net.WebUtility]::HtmlEncode([string]$result.No))</td>
    <td>$([System.Net.WebUtility]::HtmlEncode($result.Source))</td>
    <td>$([System.Net.WebUtility]::HtmlEncode($result.Name))</td>
    <td>$([System.Net.WebUtility]::HtmlEncode([string]$result.Ok))</td>
    <td>$status</td>
    <td>$([System.Net.WebUtility]::HtmlEncode([string]$result.Bytes))</td>
    <td>$([System.Net.WebUtility]::HtmlEncode($result.ContentType))</td>
    <td class="url">$([System.Net.WebUtility]::HtmlEncode($result.Url))</td>
    <td class="url">$([System.Net.WebUtility]::HtmlEncode($result.FinalUrl))</td>
    <td>$([System.Net.WebUtility]::HtmlEncode($result.Error))</td>
</tr>
"@
        }

        $html = @"
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>TVBox Link Validation Report</title>
    <style>$style</style>
</head>
<body>
    <h1>TVBox Link Validation Report</h1>
    <div class="meta">Generated: $([System.Net.WebUtility]::HtmlEncode($generatedAt))<br>Config: $([System.Net.WebUtility]::HtmlEncode($ConfigPath))</div>
    <div class="summary">
        <div class="card"><span>Total</span><strong>$($Results.Count)</strong></div>
        <div class="card"><span>Ok</span><strong>$okCount</strong></div>
        <div class="card"><span>Failed</span><strong>$failedCount</strong></div>
    </div>
    <table>
        <thead>
            <tr>
                <th>No</th><th>Source</th><th>Name</th><th>Ok</th><th>Status</th><th>Bytes</th><th>Content Type</th><th>URL</th><th>Final URL</th><th>Error</th>
            </tr>
        </thead>
        <tbody>
$($rows -join "`n")
        </tbody>
    </table>
</body>
</html>
"@

        Set-Content -LiteralPath $reportPath -Encoding UTF8 -NoNewline -Value $html
        return $reportPath
}

$resolvedPath = Resolve-Path -LiteralPath $Path
$config = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedPath | ConvertFrom-Json

$entries = @()
if ($config.urls) {
    foreach ($item in $config.urls) {
        $entries += [pscustomobject]@{
            Source = 'urls'
            Name   = [string]$item.name
            Url    = [string]$item.url
        }
    }
}
if ($config.lives) {
    foreach ($item in $config.lives) {
        $entries += [pscustomobject]@{
            Source = 'lives'
            Name   = [string]$item.name
            Url    = [string]$item.url
        }
    }
}

$timeoutMilliseconds = $TimeoutSeconds * 1000
$index = 0
$results = foreach ($entry in $entries) {
    $index++
    $result = Invoke-TvBoxLikeFetch -Url $entry.Url -TimeoutMilliseconds $timeoutMilliseconds

    [pscustomobject]@{
        No          = $index
        Source      = $entry.Source
        Name        = $entry.Name
        Ok          = $result.Ok
        Status      = $result.Status
        Bytes       = $result.Bytes
        ContentType = $result.ContentType
        Url         = $entry.Url
        FinalUrl    = $result.FinalUrl
        Error       = $result.Error
    }
}

$reportPath = $null
if (-not $NoHtml) {
    $reportPath = New-HtmlReport -Results @($results) -ConfigPath $resolvedPath.Path -OutputDirectory $ResultsDirectory
}

if ($AsJson) {
    $results | ConvertTo-Json -Depth 5
}
else {
    $results | Format-Table No, Source, Name, Ok, Status, Bytes, ContentType -AutoSize -Wrap
    ''
    'Summary:'
    $results | Group-Object Ok | Sort-Object Name | ForEach-Object { "Ok=$($_.Name): $($_.Count)" }

    $failed = @($results | Where-Object { -not $_.Ok })
    if ($failed.Count -gt 0) {
        ''
        'Failed:'
        $failed | Select-Object No, Source, Name, Status, Error, Url | Format-List
    }

    if ($reportPath) {
        ''
        "HTML report: $reportPath"
    }
}

if ($FailOnUnavailable -and @($results | Where-Object { -not $_.Ok }).Count -gt 0) {
    exit 1
}
