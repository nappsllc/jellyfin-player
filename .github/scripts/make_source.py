"""Writes an AltStore/SideStore source (apps.json) describing one JellyPlayer release."""
import argparse
import datetime
import json
import os

parser = argparse.ArgumentParser()
parser.add_argument("--repo", required=True)
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True)
parser.add_argument("--ipa", required=True)
parser.add_argument("--notes", default="")
parser.add_argument("--out", required=True)
args = parser.parse_args()

base = f"https://github.com/{args.repo}"
download_url = f"{base}/releases/download/v{args.version}/JellyPlayer.ipa"
icon_url = f"https://raw.githubusercontent.com/{args.repo}/main/JellyPlayer/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
size = os.path.getsize(args.ipa)
date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
notes = args.notes.strip().splitlines()[0] if args.notes.strip() else f"JellyPlayer {args.version}"
description = "Simple Jellyfin audio player: plays a chosen folder, with shuffle and auto-play on launch."

source = {
    "name": "JellyPlayer",
    "identifier": f"io.github.{args.repo.replace('/', '.').lower()}",
    "subtitle": "Jellyfin folder audio player",
    "description": description,
    "iconURL": icon_url,
    "website": base,
    "apps": [
        {
            "name": "JellyPlayer",
            "bundleIdentifier": "pw.napps.JellyPlayer",
            "developerName": args.repo.split("/")[0],
            "subtitle": "Jellyfin folder audio player",
            "localizedDescription": description,
            "iconURL": icon_url,
            "tintColor": "AA5CE6",
            "category": "entertainment",
            # Legacy single-version fields (older AltStore/SideStore).
            "version": args.version,
            "versionDate": date,
            "versionDescription": notes,
            "downloadURL": download_url,
            "size": size,
            "versions": [
                {
                    "version": args.version,
                    "buildVersion": args.build,
                    "date": date,
                    "localizedDescription": notes,
                    "downloadURL": download_url,
                    "size": size,
                    "minOSVersion": "17.0",
                }
            ],
            "appPermissions": {
                "entitlements": [],
                "privacy": {
                    "NSLocalNetworkUsageDescription": "JellyPlayer connects to your Jellyfin server on your local network."
                },
            },
        }
    ],
    "news": [],
}

with open(args.out, "w") as f:
    json.dump(source, f, indent=2)
