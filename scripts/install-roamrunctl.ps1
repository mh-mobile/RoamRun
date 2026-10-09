# Puts roamrunctl from a RoamRun release in %LOCALAPPDATA%\Programs\roamrunctl and on your PATH (Windows):
#   irm https://raw.githubusercontent.com/mh-mobile/RoamRun/main/scripts/install-roamrunctl.ps1 | iex
# $env:ROAMRUNCTL_VERSION picks a release other than the newest; $env:ROAMRUNCTL_FROM, where a
# release's files are (for trying archives before they are released).
$ErrorActionPreference = 'Stop'
$repo = 'mh-mobile/RoamRun'
$version = if ($env:ROAMRUNCTL_VERSION) { $env:ROAMRUNCTL_VERSION }
           else { (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name.TrimStart('v') }
$name = "roamrunctl-$version-windows-x86_64"
$from = if ($env:ROAMRUNCTL_FROM) { $env:ROAMRUNCTL_FROM } else { "https://github.com/$repo/releases/download/v$version" }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
New-Item -ItemType Directory $tmp | Out-Null
try {
    Invoke-WebRequest "$from/$name.zip" -OutFile "$tmp\$name.zip" -UseBasicParsing
    Invoke-WebRequest "$from/roamrunctl-$version-SHA256SUMS" -OutFile "$tmp\sums" -UseBasicParsing
    # What came is what the release lists: not a page in its place, nor half of it.
    $listed = Get-Content "$tmp\sums" | Where-Object { $_ -match " \*?$([regex]::Escape("$name.zip"))$" } | Select-Object -First 1
    $have = (Get-FileHash "$tmp\$name.zip" -Algorithm SHA256).Hash.ToLower()
    if (-not $listed -or $listed.Split(' ')[0].ToLower() -ne $have) { throw "$name.zip isn't the file the release lists" }
    Expand-Archive "$tmp\$name.zip" $tmp
    $dir = Join-Path $env:LOCALAPPDATA 'Programs\roamrunctl'
    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item "$tmp\$name\*" $dir -Force
    Write-Host "roamrunctl $version is in $dir"
    $path = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($path -split ';') -notcontains $dir) {
        [Environment]::SetEnvironmentVariable('Path', (@($path, $dir) | Where-Object { $_ }) -join ';', 'User')
        Write-Host "That folder is on your PATH from the next terminal you open."
    }
} finally {
    Remove-Item -Recurse -Force $tmp
}
