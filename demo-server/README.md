# JellyPlayer demo server

A tiny Jellyfin-compatible server that runs as a Cloudflare Worker, for App Review and testing. It has 3 albums and 11 songs. The songs are short generated melodies and the covers are generated pictures, so nothing needs a license. One song has a very long title and artist, to test the sliding text.

Sign in with username `demo` and password `demo`.

## Deploy from Windows (one command)
Open PowerShell and run:
```
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/nappsllc/jellyfin-player/main/demo-server/deploy.ps1 | iex"
```
It installs Node.js if it's missing, opens the browser to sign in to Cloudflare, deploys, checks the server answers, and copies its URL.

## Or deploy from the Cloudflare dashboard (about 2 minutes)
1. Go to dash.cloudflare.com, then **Workers & Pages**, then **Create**, then **Start with Hello World**. Name it `jellyplayer-demo` and click **Deploy**.
2. Click **Edit code**, replace everything with the contents of `worker.js`, and click **Deploy**.
3. The server URL is `https://jellyplayer-demo.<your-subdomain>.workers.dev`.

## Or with Wrangler
```
cd demo-server && npx wrangler deploy
```
