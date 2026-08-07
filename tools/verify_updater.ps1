<#
.SYNOPSIS
  Verifies the NewBegin updater + compiler endpoints after a deployment.
.DESCRIPTION
  Checks: /health, /compile auth (401 without key, valid compile with key),
  /version.json, /releases.json, /releases page, apkUrl reachability,
  apkSize match, sha256 match, and applicationId/versionCode validity.
  Exits non-zero if any check fails.
.PARAMETER BaseUrl
  Public base URL. Default: https://cloud-compiler-black.vercel.app
.PARAMETER ApiKey
  Compiler API key (required for the valid-compile check). Reads from the
  BLOB_READ_WRITE_TOKEN-free temp file if not provided.
.EXAMPLE
  .\verify_updater.ps1 -ApiKey "..."
#>
param(
    [string]$BaseUrl = "https://cloud-compiler-black.vercel.app",
    [string]$ApiKey,
    [switch]$SkipCompile
)

$ErrorActionPreference = "Stop"
$work = Join-Path $env:TEMP ("newbegin-verify-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null

function Assert-Check([string]$name, [bool]$ok, [string]$detail) {
    Write-Host ("  {0} {1} - {2}" -f ($(if ($ok) { "PASS" } else { "FAIL" })), $name, $detail)
    if (-not $ok) { $script:failed = $true }
}

if (-not $ApiKey -and (Test-Path "$env:TEMP\opencode\cc-apikey.txt")) {
    $ApiKey = (Get-Content "$env:TEMP\opencode\cc-apikey.txt" -Raw).Trim()
}

Write-Host "== Verifying $BaseUrl =="

# 1. health unchanged
$h = curl.exe -s -o "$work\health.json" -w "%{http_code}" "$BaseUrl/health"
$health = Get-Content "$work\health.json" -Raw | ConvertFrom-Json
Assert-Check "/health reachable" ($h -eq '200') "HTTP $h"
Assert-Check "/health service intact" ($health.success -eq $true -and $health.service -eq 'newbegin-arduino-compiler') "success=$($health.success) service=$($health.service)"

# 2. compiler auth still required
if (-not $SkipCompile) {
    $body = '{"source":"void setup(){pinMode(13,OUTPUT);} void loop(){digitalWrite(13,HIGH);}","board":"arduino_uno","format":"hex"}'
    Set-Content "$work\b.json" $body -NoNewline -Encoding ascii
    $noAuth = curl.exe -s -o "$work\noauth.json" -w "%{http_code}" -X POST -H "Content-Type: application/json" --data-binary "@$work\b.json" "$BaseUrl/compile"
    Assert-Check "/compile rejects no key" ($noAuth -eq '401') "HTTP $noAuth"
    if ($ApiKey) {
        $wrong = curl.exe -s -o "$work\wrong.json" -w "%{http_code}" -X POST -H "Content-Type: application/json" -H "X-API-Key: wrong" --data-binary "@$work\b.json" "$BaseUrl/compile"
        Assert-Check "/compile rejects wrong key" ($wrong -eq '401') "HTTP $wrong"
        $ok = curl.exe -s -o "$work\ok.json" -w "%{http_code}" -X POST -H "Content-Type: application/json" -H "X-API-Key: $ApiKey" --data-binary "@$work\b.json" "$BaseUrl/compile"
        $comp = Get-Content "$work\ok.json" -Raw | ConvertFrom-Json
        Assert-Check "/compile valid (key)" ($ok -eq '200' -and $comp.success -eq $true -and $comp.firmwareSize -gt 0) "HTTP $ok success=$($comp.success) size=$($comp.firmwareSize)"
    } else {
        Write-Host "  SKIP valid-compile (no ApiKey provided)"
    }
}

# 3. version.json
$v = curl.exe -s -o "$work\version.json" -w "%{http_code}" "$BaseUrl/version.json"
$ver = $null
try { $ver = Get-Content "$work\version.json" -Raw | ConvertFrom-Json } catch {}
Assert-Check "/version.json reachable + JSON" ($v -eq '200' -and $null -ne $ver) "HTTP $v"
if ($ver) {
    Assert-Check "version.json schemaVersion" ($ver.schemaVersion -eq 1) "schemaVersion=$($ver.schemaVersion)"
    Assert-Check "version.json versionCode int" ($ver.versionCode -is [int] -or $ver.versionCode -as [int] -is [int]) "versionCode=$($ver.versionCode)"
    Assert-Check "version.json applicationId" ($ver.applicationId -eq 'com.newbegin.coding') "applicationId=$($ver.applicationId)"
    Assert-Check "version.json apkUrl set" ($ver.apkUrl -match '^https://') "apkUrl=$($ver.apkUrl)"
    Assert-Check "version.json sha256 hex" ($ver.sha256 -match '^[0-9A-Fa-f]{64}$') "sha256=$($ver.sha256)"
}

# 4. releases.json
$r = curl.exe -s -o "$work\releases.json" -w "%{http_code}" "$BaseUrl/releases.json"
$rel = $null
try { $rel = @(Get-Content "$work\releases.json" -Raw | ConvertFrom-Json) } catch {}
Assert-Check "/releases.json reachable + JSON array" ($r -eq '200' -and $rel.Count -ge 1) "HTTP $r count=$($rel.Count)"

# 5. releases page
$pg = curl.exe -s -o "$work\page.html" -w "%{http_code}" "$BaseUrl/releases"
Assert-Check "/releases page HTML" ($pg -eq '200' -and ((Get-Content "$work\page.html" -Raw) -match '<html')) "HTTP $pg"

# 6-8. apkUrl / size / sha256
if ($ver -and $ver.apkUrl) {
    $apkHttp = curl.exe -s -o "$work\apk.bin" -w "%{http_code} %{size_download}" -L $ver.apkUrl
    Assert-Check "apkUrl reachable" ($apkHttp -match '^200 ') "HTTP $apkHttp"
    if (Test-Path "$work\apk.bin") {
        $dlSize = (Get-Item "$work\apk.bin").Length
        Assert-Check "apkSize matches" ($dlSize -eq $ver.apkSize) "download=$dlSize manifest=$($ver.apkSize)"
        $dlHash = (Get-FileHash -LiteralPath "$work\apk.bin" -Algorithm SHA256).Hash
        Assert-Check "sha256 matches" ($dlHash -eq $ver.sha256.ToUpper()) "hash=$dlHash"
    }
}

# 9. applicationId/versionCode valid
if ($ver) {
    Assert-Check "applicationId valid" ($ver.applicationId -match '^[a-zA-Z0-9_.]+$') "applicationId=$($ver.applicationId)"
    Assert-Check "versionCode >= 1" ($ver.versionCode -ge 1) "versionCode=$($ver.versionCode)"
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
if ($script:failed) { Write-Host "`nRESULT: FAILED"; exit 1 }
Write-Host "`nRESULT: ALL CHECKS PASSED"
