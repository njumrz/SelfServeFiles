<#
.SYNOPSIS
Validates and repairs GitHub raw proxy URLs in tvbox-lines.json.

.DESCRIPTION
This script scans urls and lives entries for raw.githubusercontent.com links, including links wrapped
by common GitHub proxy prefixes. For each GitHub raw link, it simulates the TVBox/OkHttp request layer.

Behavior:
- If the current URL is reachable, it is kept.
- If the current URL is not reachable, candidate GitHub proxy prefixes are tested.
- The first reachable candidate replaces the failed URL when -Apply is provided.
- Without -Apply, the script only reports planned replacements.

This script intentionally validates only network reachability. It does not parse TVBox JSON, M3U, or
image-disguised payloads.

.PARAMETER Path
Path to tvbox-lines.json.

.PARAMETER TimeoutSeconds
Request timeout per URL.

.PARAMETER Apply
Apply replacements to the JSON file. If omitted, the script runs in dry-run mode.

.PARAMETER CandidatePrefixes
GitHub proxy prefixes to try. Each prefix must accept the form: <prefix>https://raw.githubusercontent.com/...

.PARAMETER AsJson
Print result objects as JSON instead of a table.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Path = (Join-Path $PSScriptRoot '..\tvbox-lines.json'),

    [Parameter()]
    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 10,

    [Parameter()]
    [switch]$Apply,

    [Parameter()]
    [string[]]$CandidatePrefixes = @(
        'https://gh-proxy.com/',
        'https://gh.ddlc.top/',
        'https://gh.llkk.cc/',
        'https://ghproxy.net/',
        'https://gh-proxy.net/',
        'https://ghfast.top/',
        'https://ghfast.net/',
        'https://ghproxy.cc/',
        'https://hub.gitmirror.com/',
        'https://gh-proxy.ygxz.in/'
    ),

    [Parameter()]
    [switch]$AsJson
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
        # Let the network request surface the original URL failure.
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
                Ok          = ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400 -and $bytes -gt 0)
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

function Get-RawGitHubUrl {
    param([Parameter(Mandatory)][string]$Url)

    if ($Url -match '(https://raw\.githubusercontent\.com/.+)$') {
        return $Matches[1]
    }

    return $null
}

function Join-ProxyUrl {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$RawUrl
    )

    return $Prefix.TrimEnd('/') + '/' + $RawUrl
}

$resolvedPath = Resolve-Path -LiteralPath $Path
$fileText = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedPath
$config = $fileText | ConvertFrom-Json

$entries = @()
if ($config.urls) {
    foreach ($item in $config.urls) {
        $entries += [pscustomobject]@{ Source = 'urls'; Name = [string]$item.name; Url = [string]$item.url }
    }
}
if ($config.lives) {
    foreach ($item in $config.lives) {
        $entries += [pscustomobject]@{ Source = 'lives'; Name = [string]$item.name; Url = [string]$item.url }
    }
}

$timeoutMilliseconds = $TimeoutSeconds * 1000
$results = @()
$replacementByUrl = @{}
$index = 0

foreach ($entry in $entries) {
    $index++
    $rawUrl = Get-RawGitHubUrl -Url $entry.Url
    if (-not $rawUrl) {
        continue
    }

    $current = Invoke-TvBoxLikeFetch -Url $entry.Url -TimeoutMilliseconds $timeoutMilliseconds
    $selectedUrl = $entry.Url
    $selected = $current
    $action = if ($current.Ok) { 'KeepCurrent' } else { 'NoReplacementFound' }

    if (-not $current.Ok) {
        foreach ($prefix in $CandidatePrefixes) {
            $candidateUrl = Join-ProxyUrl -Prefix $prefix -RawUrl $rawUrl
            if ($candidateUrl -eq $entry.Url) {
                continue
            }

            $candidate = Invoke-TvBoxLikeFetch -Url $candidateUrl -TimeoutMilliseconds $timeoutMilliseconds
            if ($candidate.Ok) {
                $selectedUrl = $candidateUrl
                $selected = $candidate
                $action = if ($Apply) { 'Replace' } else { 'WouldReplace' }
                $replacementByUrl[$entry.Url] = $selectedUrl
                break
            }
        }
    }

    $results += [pscustomobject]@{
        No             = $index
        Source         = $entry.Source
        Name           = $entry.Name
        CurrentOk      = $current.Ok
        CurrentStatus  = $current.Status
        Action         = $action
        SelectedOk     = $selected.Ok
        SelectedStatus = $selected.Status
        SelectedBytes  = $selected.Bytes
        CurrentUrl     = $entry.Url
        SelectedUrl    = $selectedUrl
        Error          = if ($current.Ok) { '' } else { $current.Error }
    }
}

if ($Apply -and $replacementByUrl.Count -gt 0) {
    foreach ($oldUrl in $replacementByUrl.Keys) {
        $newUrl = [string]$replacementByUrl[$oldUrl]
        $fileText = $fileText.Replace($oldUrl, $newUrl)
    }

    Set-Content -LiteralPath $resolvedPath -Encoding UTF8 -NoNewline -Value $fileText
}

if ($AsJson) {
    $results | ConvertTo-Json -Depth 5
}
else {
    $results | Format-Table No, Source, Name, CurrentOk, CurrentStatus, Action, SelectedStatus, SelectedBytes -AutoSize -Wrap
    ''
    'Summary:'
    "GitHub raw/proxy links checked: $($results.Count)"
    "Replacements: $($replacementByUrl.Count)"
    if (-not $Apply -and $replacementByUrl.Count -gt 0) {
        'Dry run only. Re-run with -Apply to write replacements.'
    }

    $unfixed = @($results | Where-Object { -not $_.SelectedOk })
    if ($unfixed.Count -gt 0) {
        ''
        'Unfixed GitHub links:'
        $unfixed | Select-Object No, Source, Name, CurrentStatus, Error, CurrentUrl | Format-List
    }
}
