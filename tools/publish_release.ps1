<#
.PARAMETER ApkPath
  Path to the signed release APK (required).
.PARAMETER VersionName
  Version name, e.g. "1.3.0". Auto-derived from the APK via aapt2 when omitted.
.PARAMETER VersionCode
  Version code, e.g. 4. Auto-derived from the APK via aapt2 when omitted.
.PARAMETER ReleaseNotes
  Optional array of release note lines. Defaults to a generic note.
.PARAMETER MinimumSupportedVersionCode
  Oldest installed versionCode that may install this update. Default: 1.
.PARAMETER Required
  If $true, the update is mandatory. Default: $false.
.PARAMETER BlobBaseUrl
  Public base URL of the Blob store. Defaults to the release-store used here.
.PARAMETER ApplicationId
  Android application id. Default: com.newbegin.coding.
.PARAMETER Token
  Optional BLOB_READ_WRITE_TOKEN. If omitted, the Vercel CLI reads it from
  .env.local (gitignored) or the BLOB_READ_WRITE_TOKEN environment variable.
.EXAMPLE
  .\publish_release.ps1 -ApkPath ..\..\..\..\NewBegin Robotics\build\app\outputs\flutter-apk\app-release.apk
.DESCRIPTION
  Publishes a signed APK to Vercel Blob and updates version.json, releases.json
  and releases.html (stable pathnames, public). APKs use immutable versioned
  filenames and are never overwritten. Metadata is served through the Vercel
  edge rewrites at https://cloud-compiler-black.vercel.app - no compiler
  redeploy is required.
#>
param(
    [Parameter(Mandatory = $true)][string]$ApkPath,
    [string]$VersionName,
    [Parameter(Mandatory = $false)][int]$VersionCode = -1,
    [string[]]$ReleaseNotes,
    [int]$MinimumSupportedVersionCode = 1,
    [switch]$Required,
    [string]$BlobBaseUrl = "https://3abrdlydzjyw1e55.public.blob.vercel-storage.com",
    [string]$ApplicationId = "com.newbegin.coding",
    [string]$Token
)

$ErrorActionPreference = "Stop"
$storeDomain = $BlobBaseUrl -replace '^https://', ''
$apkUrl = "$BlobBaseUrl/newbegin-$VersionName-$VersionCode.apk"

if (-not (Test-Path -LiteralPath $ApkPath)) { throw "APK not found: $ApkPath" }
$apkItem = Get-Item -LiteralPath $ApkPath
$apkSize = $apkItem.Length
$sha256 = (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash

if ($VersionName -eq '' -or $VersionCode -lt 0) {
    $aapt = $null
    foreach ($base in @("$env:LOCALAPPDATA\Android\Sdk", "$env:ANDROID_HOME", "$env:ANDROID_SDK_ROOT")) {
        if (-not $base) { continue }
        $cand = Get-ChildItem "$base\build-tools" -Recurse -Filter "aapt2.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($cand) { $aapt = $cand.FullName; break }
    }
    if (-not $aapt) { throw "VersionName/VersionCode not provided and aapt2 not found." }
    $badging = & $aapt dump badging $ApkPath 2>$null
    $vm = ($badging | Select-String "versionName='([^']+)'").Matches[0].Groups[1].Value
    $vc = ($badging | Select-String "versionCode='(\d+)'").Matches[0].Groups[1].Value
    if ($VersionName -eq '') { $VersionName = $vm }
    if ($VersionCode -lt 0) { $VersionCode = [int]$vc }
}
if (-not $ReleaseNotes) { $ReleaseNotes = @("NewBegin $VersionName (build $VersionCode)") }
$publishedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
$filename = "newbegin-$VersionName-$VersionCode.apk"
$apkUrl = "$BlobBaseUrl/$filename"
if (-not $Token) {
    if ($env:BLOB_READ_WRITE_TOKEN) { $Token = $env:BLOB_READ_WRITE_TOKEN }
    elseif (Test-Path ".env.local") {
        $l = Get-Content ".env.local" | Where-Object { $_ -match '^BLOB_READ_WRITE_TOKEN=' }
        if ($l) { $Token = ($l -split '=', 2)[1].Trim().Trim('"') }
    }
}
if (-not $Token) { throw "No BLOB_READ_WRITE_TOKEN. Set it, pass -Token, or run inside the repo where .env.local exists." }

$env:BLOB_READ_WRITE_TOKEN = $Token

function Invoke-BlobPut($file, $pathname, $ct, [switch]$AllowOverwrite) {
    $args = @("blob", "put", $file, "--access", "public", "--pathname", $pathname, "--content-type", $ct)
    if ($AllowOverwrite) { $args += "--allow-overwrite" }
    $out = (& vercel @args 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "vercel blob put failed for $pathname`: $out" }
    $u = [regex]::Match($out, 'https://[^\s"]+\.vercel-storage\.com/[^\s"]+').Value
    if (-not $u) { throw "Could not extract URL from vercel blob put output for $pathname" }
    return $u
}

Write-Host "== NewBegin release publish =="
Write-Host " APK:        $ApkPath"
Write-Host " version:    $VersionName ($VersionCode)"
Write-Host " size:       $apkSize bytes"
Write-Host " sha256:     $sha256"
Write-Host " blob store: $storeDomain"

Write-Host "`n[1/6] Uploading APK (immutable, no overwrite)..."
$apkUrl = Invoke-BlobPut $ApkPath $filename "application/vnd.android.package-archive"
Write-Host "  $apkUrl"

Write-Host "`n[2/6] Loading existing release history..."
$releases = @()
try {
    $cur = curl.exe -s -o NUL -w "%{http_code}" "$BlobBaseUrl/releases.json"
    if ($cur -eq '200') {
        $body = curl.exe -s "$BlobBaseUrl/releases.json"
        $releases = @($body | ConvertFrom-Json)
    }
} catch { Write-Host "  (history unavailable, starting fresh)" }

$record = [ordered]@{
    versionName  = $VersionName
    versionCode  = $VersionCode
    publishedAt  = $publishedAt
    apkUrl       = $apkUrl
    sha256       = $sha256
    apkSize      = $apkSize
    releaseNotes = @($ReleaseNotes)
}
$releases = @($record) + @($releases)

$version = [ordered]@{
    schemaVersion               = 1
    versionName                 = $VersionName
    versionCode                 = $VersionCode
    minimumSupportedVersionCode = $MinimumSupportedVersionCode
    required                    = [bool]$Required
    publishedAt                 = $publishedAt
    apkUrl                      = $apkUrl
    sha256                      = $sha256
    apkSize                     = $apkSize
    applicationId               = $ApplicationId
    releaseNotes                = @($ReleaseNotes)
}

$work = Join-Path $env:TEMP ("newbegin-publish-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$version | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $work "version.json") -Encoding ascii
$releases | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $work "releases.json") -Encoding ascii

$sizeMb = [math]::Round($apkSize / 1MB, 1)
$notes = ($ReleaseNotes | ForEach-Object { "    <li>$($_.Replace('<','&lt;').Replace('>','&gt;'))</li>" }) -join "`n"
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NewBegin Releases</title>
<style>
  body { font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #f6f7f9; color: #1b1f23; }
  .wrap { max-width: 720px; margin: 0 auto; padding: 40px 20px; }
  h1 { font-size: 1.6rem; }
  .card { background: #fff; border: 1px solid #e1e4e8; border-radius: 10px; padding: 24px; margin: 16px 0; }
  .meta { color: #586069; font-size: .92rem; }
  .dl { display: inline-block; background: #1f883d; color: #fff; text-decoration: none; padding: 10px 18px; border-radius: 6px; margin-top: 8px; }
  .dl:hover { background: #18752f; }
  code { background: #f1f3f5; padding: 2px 6px; border-radius: 4px; word-break: break-all; font-size: .85rem; }
  .note { background: #fff8c5; border: 1px solid #f0e6a8; border-radius: 8px; padding: 12px 16px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>NewBegin Releases</h1>
  <div class="card">
    <h2>NewBegin $VersionName (build $VersionCode)</h2>
    <p class="meta">Released $($publishedAt.Split('T')[0]) &middot; application id: $ApplicationId</p>
    <a class="dl" href="$apkUrl">Download APK ($sizeMb MB)</a>
    <p><strong>Release notes</strong></p>
    <ul>
$notes
    </ul>
    <p class="meta"><strong>SHA-256:</strong><br><code>$sha256</code></p>
    <p class="meta"><strong>File size:</strong> $apkSize bytes ($sizeMb MB)</p>
    <p class="note"><strong>Installation note:</strong> Allow installation from unknown sources for this app. On Android this is usually Settings &rarr; Apps &rarr; Special app access &rarr; Install unknown apps, or you will be prompted to permit the browser download. Only install APKs from this official page.</p>
  </div>
</div>
</body>
</html>
"@
Set-Content (Join-Path $work "releases.html") $html -Encoding ascii -NoNewline

Write-Host "`n[3/6] Uploading metadata (stable pathnames, overwrite allowed)..."
$vUrl = Invoke-BlobPut (Join-Path $work "version.json") "version.json" "application/json" -AllowOverwrite
$rUrl = Invoke-BlobPut (Join-Path $work "releases.json") "releases.json" "application/json" -AllowOverwrite
$hUrl = Invoke-BlobPut (Join-Path $work "releases.html") "releases.html" "text/html" -AllowOverwrite
Write-Host "  $vUrl"
Write-Host "  $rUrl"
Write-Host "  $hUrl"

Write-Host "`n[4/6] Verifying public URLs..."
foreach ($u in @($vUrl, $rUrl, $hUrl, $apkUrl)) {
    $code = curl.exe -s -o NUL -w "%{http_code}" $u
    if ($code -ne '200') { throw "URL not reachable: $u (HTTP $code)" }
    Write-Host "  OK $code $u"
}

Write-Host "`n[5/6] Verifying APK checksum..."
$dl = Join-Path $work "verify.apk"
curl.exe -s -L -o $dl $apkUrl | Out-Null
$dlHash = (Get-FileHash -LiteralPath $dl -Algorithm SHA256).Hash
if ($dlHash -ne $sha256) { throw "SHA-256 mismatch: expected $sha256 got $dlHash" }
Write-Host "  sha256 match: $dlHash"

Write-Host "`n[6/6] Release summary"
Write-Host "  version : $VersionName ($VersionCode)"
Write-Host "  apkUrl  : $apkUrl"
Write-Host "  version : $vUrl"
Write-Host "  releases: $rUrl"
Write-Host "  page    : $hUrl"
Write-Host "  sha256  : $sha256"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host "`nDone. No compiler redeploy was required."
