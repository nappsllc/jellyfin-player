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
    $out = npx --yes wrangler@4 deploy 2>&1 | Tee-Object -Variable log
    $url = ($log | Select-String -Pattern 'https://\S+\.workers\.dev' -AllMatches).Matches | Select-Object -First 1 -ExpandProperty Value
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
