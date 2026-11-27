<#
.SYNOPSIS
    Publish the DSH plugin market index to GitHub and sync the pinned jsDelivr URL in the profile.

.DESCRIPTION
    DSH's plugin_market only accepts http(s) index URLs, without credentials, and does not support file://.
    raw.githubusercontent.com succeeds about 3 out of 4 times on this host while jsDelivr is stable, but
    jsDelivr caches branch names for roughly 12 hours, so the profile pins an exact commit. Pinning a commit
    means the URL changes on every publish; this script performs the whole chain:

        validate index.json -> push -> read the new commit -> rewrite the profile index URL

    Validation mirrors @deepseek-ai/dsh-plugin-market-index parseMarketIndex. The rules that cost time:
      - versions[].publishTimestamp is required: an integer count of Unix seconds in [0, 1e11)
      - versions[].source.commit must be a lowercase 40-hex commit SHA (no tags, no short SHAs)
      - repository.directory, when present, must be a non-blank string; omit it for a single-package repo
      - plugins[].metadata.labels[] may only reference ids declared in top-level metadata.labels
      - plugins[].metadata accepts only category / keywords / labels / sortKeys; sortOrder is not an index field

.PARAMETER Refresh
    Refresh version / commit / publishTimestamp from each plugin repo's master HEAD before publishing.

.PARAMETER DryRun
    Validate and print the plan without pushing or changing the profile.

.EXAMPLE
    .\publish-index.ps1 -DryRun

.EXAMPLE
    .\publish-index.ps1 -Refresh

.EXAMPLE
    .\publish-index.ps1
#>
[CmdletBinding()]
param(
    [switch]$Refresh,
    [switch]$DryRun,
    [string]$IndexFile = '',
    [string]$Repo = 'AlawnWalker/aw-plugin-bazaar',
    [string]$Branch = 'master',
    [string]$ProfileDir = '',
    [string]$TokenFile = (Join-Path $env:USERPROFILE '.dsh\secure\github-token')
)

# param 默认值求值时 $PSScriptRoot 可能为空（-File 模式），这里再解析一次
if ([string]::IsNullOrWhiteSpace($IndexFile)) {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $IndexFile = Join-Path $scriptDir 'index.json'
}
if ([string]::IsNullOrWhiteSpace($ProfileDir) -and $env:DSH_HOME) {
    $ProfileDir = Join-Path $env:DSH_HOME 'profiles\desktop'
}

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Step([string]$text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Ok([string]$text) { Write-Host "    OK  $text" -ForegroundColor Green }
function Write-Note([string]$text) { Write-Host "    !   $text" -ForegroundColor Yellow }

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [string]$BodyFile = ''
    )
    $argv = @('-s', '--max-time', '40', '-X', $Method,
              '-H', "Authorization: Bearer $token",
              '-H', 'Accept: application/vnd.github+json',
              '-H', 'User-Agent: dsh-market-publish')
    if ($BodyFile -ne '') { $argv += @('-H', 'Content-Type: application/json', '--data-binary', "@$BodyFile") }
    $argv += $Uri
    $resp = & curl.exe @argv
    if ([string]::IsNullOrWhiteSpace($resp)) { throw "GitHub API returned nothing: $Method $Uri" }
    return $resp | ConvertFrom-Json
}

# ---------------- token ----------------
if (-not (Test-Path -LiteralPath $TokenFile)) { throw "token file missing: $TokenFile" }
$token = (Get-Content -LiteralPath $TokenFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($token)) { throw "token file is empty: $TokenFile" }

# ---------------- load ----------------
Write-Step 'Reading index'
if (-not (Test-Path -LiteralPath $IndexFile)) { throw "index file missing: $IndexFile" }
$indexText = [IO.File]::ReadAllText($IndexFile, $utf8)
$index = $indexText | ConvertFrom-Json
Write-Ok "$IndexFile with $($index.plugins.Count) plugins"

# ---------------- optional refresh ----------------
if ($Refresh) {
    Write-Step 'Refreshing version, commit and publishTimestamp from each repo master HEAD'
    foreach ($plugin in $index.plugins) {
        $repoUrl = [string]$plugin.repository.url
        if ($repoUrl -notmatch '^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?$') {
            Write-Note "$($plugin.name): repository.url is not a github.com URL, skipped"
            continue
        }
        $owner = $Matches[1]
        $name = $Matches[2]
        $commit = Invoke-GitHubApi -Uri "https://api.github.com/repos/$owner/$name/commits/$Branch"
        $sha = [string]$commit.sha
        if ($sha -notmatch '^[0-9a-f]{40}$') {
            Write-Note "$($plugin.name): unexpected sha, skipped"
            continue
        }
        $pkgResp = Invoke-GitHubApi -Uri "https://api.github.com/repos/$owner/$name/contents/package.json?ref=$sha"
        $pkgText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((($pkgResp.content) -replace "`n", '')))
        $pkg = $pkgText | ConvertFrom-Json

        $version = [string]$pkg.version
        $iso = [string]$commit.commit.committer.date
        $ts = [DateTimeOffset]::Parse($iso).ToUnixTimeSeconds()

        $plugin.versions[0].version = $version
        $plugin.versions[0].source.commit = $sha
        $plugin.versions[0].publishTimestamp = $ts
        $plugin.versions[0].source.url = "https://github.com/$owner/$name"
        $plugin.repository.url = "https://github.com/$owner/$name"
        $plugin.author = 'aw-plugin-bazaar'

        Write-Ok ("{0,-26} v{1,-8} {2} {3}" -f $plugin.name, $version, $sha.Substring(0, 8), $iso)
    }
    $indexText = $index | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($IndexFile, ($indexText + "`n"), $utf8)
    $index = $indexText | ConvertFrom-Json
    Write-Ok 'index.json rewritten'
}

# ---------------- validate ----------------
Write-Step 'Validating against the DSH index schema'
$problems = New-Object System.Collections.Generic.List[string]
$declaredCategories = @($index.metadata.categories.PSObject.Properties.Name)
$declaredLabels = @($index.metadata.labels.PSObject.Properties.Name)

if ($index.format -ne 1) { $problems.Add('$.format must be 1') }
if (-not $index.plugins -or $index.plugins.Count -eq 0) { $problems.Add('$.plugins must be a non-empty array') }

$seenNames = @{}
foreach ($p in $index.plugins) {
    $pname = [string]$p.name
    if ($pname -notmatch '^[a-z0-9@][a-z0-9@/_.-]*$') { $problems.Add("[$pname] name is not a valid npm package name") }
    if ($seenNames.ContainsKey($pname)) { $problems.Add("[$pname] duplicate plugin name") } else { $seenNames[$pname] = 1 }

    if ($p.repository) {
        $rurl = [string]$p.repository.url
        if ($rurl -notmatch '^https?://') { $problems.Add("[$pname] repository.url must be http(s)") }
        if ($null -ne $p.repository.directory) {
            if ([string]::IsNullOrWhiteSpace([string]$p.repository.directory)) {
                $problems.Add("[$pname] repository.directory must not be blank; omit the field instead")
            }
        }
    }

    if ($p.metadata) {
        $cat = [string]$p.metadata.category
        if ($cat -ne '' -and ($declaredCategories -notcontains $cat)) {
            $problems.Add("[$pname] category '$cat' is not declared at the top level")
        }
        foreach ($label in @($p.metadata.labels)) {
            if ($label -and ($declaredLabels -notcontains $label)) {
                $problems.Add("[$pname] label '$label' is not declared at the top level")
            }
        }
        $unknown = @($p.metadata.PSObject.Properties.Name | Where-Object { @('category', 'keywords', 'labels', 'sortKeys') -notcontains $_ })
        if ($unknown.Count -gt 0) {
            $problems.Add("[$pname] metadata has unknown keys: $($unknown -join ', '); sortOrder is not an index field")
        }
    }

    if (-not $p.versions -or $p.versions.Count -eq 0) { $problems.Add("[$pname] versions must be a non-empty array") }
    $seenVersions = @{}
    foreach ($v in @($p.versions)) {
        $ver = [string]$v.version
        if ($ver -notmatch '^\d+\.\d+\.\d+') { $problems.Add("[$pname] version '$ver' is not exact SemVer") }
        if ($seenVersions.ContainsKey($ver)) { $problems.Add("[$pname] duplicate version $ver") } else { $seenVersions[$ver] = 1 }

        $stamp = $v.publishTimestamp
        if ($null -eq $stamp) {
            $problems.Add("[$pname] version $ver is missing publishTimestamp (required integer Unix seconds)")
        } else {
            $asText = [string]$stamp
            if ($asText -notmatch '^\d+$') {
                $problems.Add("[$pname] version $ver publishTimestamp is not an integer")
            } else {
                $n = [long]$asText
                if ($n -lt 0 -or $n -ge 100000000000) {
                    $problems.Add("[$pname] version $ver publishTimestamp is outside [0, 1e11)")
                }
            }
        }

        $type = [string]$v.source.type
        if ($type -eq 'git') {
            if (([string]$v.source.commit) -notmatch '^[0-9a-f]{40}$') {
                $problems.Add("[$pname] version $ver commit must be a lowercase 40-hex SHA")
            }
            $surl = [string]$v.source.url
            if ($surl -notmatch '^https://[^/]+/.+/.+') {
                $problems.Add("[$pname] version $ver source.url must be canonical https with at least two segments")
            }
            if ($surl -match '\.(tgz|tar\.gz)$') { $problems.Add("[$pname] version $ver source.url points at a tarball") }
            if ($surl -match '[?#]') { $problems.Add("[$pname] version $ver source.url must not carry a query or fragment") }
        } elseif ($type -eq 'npm') {
            if ($v.source.registry -and (([string]$v.source.registry) -notmatch '^https?://')) {
                $problems.Add("[$pname] version $ver registry must be http(s)")
            }
        } else {
            $problems.Add("[$pname] version $ver source.type must be npm or git")
        }
    }
}

if ($problems.Count -gt 0) {
    Write-Host ""
    Write-Host "Validation failed with $($problems.Count) problem(s):" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw 'index did not validate; nothing was published'
}
Write-Ok "passed: $($index.plugins.Count) plugins, $($declaredLabels.Count) labels, $($declaredCategories.Count) categories"

if ($DryRun) {
    Write-Step 'DryRun plan'
    foreach ($p in $index.plugins) {
        $v = $p.versions[0]
        Write-Host ("    {0,-26} v{1,-8} ts={2,-12} {3}" -f $p.name, $v.version, $v.publishTimestamp, ([string]$v.source.commit).Substring(0, 8))
    }
    Write-Host ""
    Write-Host '[DryRun] nothing pushed, profile untouched.' -ForegroundColor Yellow
    return
}

# ---------------- push ----------------
Write-Step "Pushing to $Repo@$Branch"
$normalized = ($index | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
$tmpJson = [IO.Path]::GetTempFileName()
$bodyFile = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($tmpJson, ($normalized + "`n"), $utf8)
    $remote = Invoke-GitHubApi -Uri "https://api.github.com/repos/$Repo/contents/index.json"
    $payload = [ordered]@{
        message = 'Update market index'
        content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tmpJson))
        sha     = [string]$remote.sha
        branch  = $Branch
        author  = [ordered]@{ name = 'aw-plugin-bazaar'; email = 'noreply@aw-plugin-bazaar.invalid' }
        committer = [ordered]@{ name = 'aw-plugin-bazaar'; email = 'noreply@aw-plugin-bazaar.invalid' }
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($bodyFile, $payload, $utf8)
    $put = Invoke-GitHubApi -Method PUT -Uri "https://api.github.com/repos/$Repo/contents/index.json" -BodyFile $bodyFile
} finally {
    Remove-Item -LiteralPath $tmpJson -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
}

$newCommit = [string]$put.commit.sha
if ($newCommit -notmatch '^[0-9a-f]{40}$') { throw "push returned an unexpected commit: $newCommit" }
Write-Ok "new commit $newCommit"

$newUrl = "https://cdn.jsdelivr.net/gh/$Repo@$newCommit/index.json"

# ---------------- update profile ----------------
Write-Step 'Syncing the profile index URL'
if ([string]::IsNullOrWhiteSpace($ProfileDir) -or -not (Test-Path -LiteralPath $ProfileDir)) {
    Write-Note "profile dir not found; set this URL manually:"
    Write-Host "    $newUrl" -ForegroundColor Yellow
    return
}
$patchPath = Join-Path $ProfileDir 'cordis.patch.yml'
if (-not (Test-Path -LiteralPath $patchPath)) { throw "missing cordis.patch.yml: $patchPath" }

$patchText = [IO.File]::ReadAllText($patchPath, $utf8)
$pattern = '(?m)^(\s*-\s*)https://cdn\.jsdelivr\.net/gh/' + [regex]::Escape($Repo) + '@[0-9a-f]{40}/index\.json[ \t]*$'
if ($patchText -notmatch $pattern) {
    Write-Note "no pinned $Repo index line in the profile; add it manually:"
    Write-Host "    - $newUrl" -ForegroundColor Yellow
    return
}
$backup = "$patchPath.bak-market"
Copy-Item -LiteralPath $patchPath -Destination $backup -Force
$patched = [regex]::Replace($patchText, $pattern, "`${1}$newUrl")
[IO.File]::WriteAllText($patchPath, $patched, $utf8)
Write-Ok "updated $patchPath (backup $backup)"

Write-Host ""
Write-Host 'Done.' -ForegroundColor Green
Write-Host "  index commit : $newCommit"
Write-Host "  CDN URL      : $newUrl"
Write-Host ''
Write-Host 'Next: restart DSH so the new index is read (market cacheTtlMs defaults to 10 minutes).' -ForegroundColor Yellow
