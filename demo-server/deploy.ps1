# Deploys the JellyPlayer demo server to your Cloudflare account.
# Run in PowerShell:
#   powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/nappsllc/jellyfin-player/main/demo-server/deploy.ps1 | iex"
# The first run opens the browser to sign in to Cloudflare.

$ErrorActionPreference = 'Stop'

if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    Write-Host 'Node.js not found, installing it with winget...'
    winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

$dir = Join-Path $env:TEMP 'jellyplayer-demo'
New-Item -ItemType Directory -Force $dir | Out-Null
$base = 'https://raw.githubusercontent.com/nappsllc/jellyfin-player/main/demo-server'
Invoke-WebRequest "$base/worker.js" -OutFile "$dir\worker.js" -UseBasicParsing
Invoke-WebRequest "$base/wrangler.toml" -OutFile "$dir\wrangler.toml" -UseBasicParsing

Push-Location $dir
try {
    # wrangler writes progress to stderr; don't let PowerShell treat that as a failure.
    $ErrorActionPreference = 'Continue'
    # Sign in first, outside any pipe, so its browser prompt works normally.
    $who = npx --yes wrangler@4 whoami 2>&1 | Out-String
    if ($who -notmatch 'Account ID') { npx --yes wrangler@4 login }
    $lines = npx --yes wrangler@4 deploy 2>&1 | ForEach-Object { "$_" }
    $lines | Write-Host
    if ($LASTEXITCODE -ne 0) { throw 'wrangler deploy failed (see above).' }
    $url = ([regex]'https://[\w.-]+\.workers\.dev').Match(($lines -join "`n")).Value
    if ($url) {
        $info = Invoke-RestMethod "$url/System/Info/Public"
        Write-Host ''
        Write-Host "Demo server is up: $url  ($($info.ServerName))" -ForegroundColor Green
        Write-Host 'Sign in to JellyPlayer with username demo and password demo.'
        Set-Clipboard $url
        Write-Host '(URL copied to the clipboard)'
    }
} finally {
    Pop-Location
}
