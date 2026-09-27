"""Generate an AltStore source from verified CManga IPAs in a configured repository."""

import json
import os
import plistlib
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path
from urllib.parse import quote, unquote, urlparse
from urllib.request import Request, urlopen

BUNDLE_ID = "com.cmanga.reader"
IPA_NAME = re.compile(r"cmanga-ios-(\d+\.\d+\.\d+)\+(\d+)\.ipa")


def configured_repository():
    repository = os.environ.get("CMANGA_RELEASE_REPOSITORY") or os.environ.get("GITHUB_REPOSITORY")
    if not repository or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Set CMANGA_RELEASE_REPOSITORY=owner/repo (or GITHUB_REPOSITORY in CI) to the real CManga release repository.")
    return repository


def github_json(path):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "CManga-AltStore"}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urlopen(Request(f"https://api.github.com/{path}", headers=headers), timeout=60) as response:
        return json.load(response)


def fetch_releases(repository):
    releases = []
    page = 1
    while True:
        batch = github_json(f"repos/{repository}/releases?per_page=100&page={page}")
        releases.extend(release for release in batch if not release["draft"] and not release["prerelease"])
        if len(batch) < 100:
            return sorted(releases, key=lambda release: release["published_at"], reverse=True)
        page += 1


def verified_ipa(repository, asset):
    match = IPA_NAME.fullmatch(asset["name"])
    if not match:
        raise ValueError(f"Refusing non-CManga IPA asset: {asset['name']}")
    version, build = match.groups()
    url = asset["browser_download_url"]
    parsed = urlparse(url)
    if (parsed.scheme != "https" or parsed.netloc != "github.com"
            or not unquote(parsed.path).startswith(f"/{repository}/releases/download/")
            or unquote(parsed.path.rsplit("/", 1)[-1]) != asset["name"]):
        raise ValueError(f"IPA URL does not belong to {repository}: {url}")
    size = asset["size"]
    if not isinstance(size, int) or size <= 0:
        raise ValueError(f"Missing real IPA size for {asset['name']}")
    # Read the distributed app, not just a filename that could disguise an upstream IPA.
    with tempfile.TemporaryFile() as downloaded:
        with urlopen(Request(url, headers={"User-Agent": "CManga-AltStore"}), timeout=120) as response:
            shutil.copyfileobj(response, downloaded)
        if downloaded.tell() != size:
            raise ValueError(f"Downloaded IPA size disagrees with release metadata: {asset['name']}")
        downloaded.seek(0)
        with zipfile.ZipFile(downloaded) as archive:
            manifests = [name for name in archive.namelist()
                         if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
            if len(manifests) != 1:
                raise ValueError(f"Expected one application Info.plist in {asset['name']}")
            info = plistlib.loads(archive.read(manifests[0]))
    if (info.get("CFBundleIdentifier") != BUNDLE_ID
            or info.get("CFBundleDisplayName", info.get("CFBundleName")) != "CManga"):
        raise ValueError(f"Refusing wrong app identity inside {asset['name']}; expected CManga ({BUNDLE_ID}).")
    if info.get("CFBundleShortVersionString") != version or str(info.get("CFBundleVersion")) != build:
        raise ValueError(f"IPA filename does not match its actual version/build: {asset['name']}")
    minimum_os = info.get("MinimumOSVersion")
    if not minimum_os:
        raise ValueError(f"Missing MinimumOSVersion in {asset['name']}")
    return {
        "version": version,
        "buildVersion": build,
        "downloadURL": url,
        "size": size,
        "minOSVersion": minimum_os,
    }


def generate_source(repository, repository_info, releases):
    website = repository_info["html_url"]
    icon_url = (f"https://raw.githubusercontent.com/{repository}/"
                f"{quote(repository_info['default_branch'], safe='')}/assets/app_icon.png")
    source = {
        "name": "CManga",
        "identifier": f"{BUNDLE_ID}.source",
        "website": website,
        "subtitle": "Comics, with local AI.",
        "description": "CManga is an independent comic reader with local AI enhancement, colorization and translation. IPAs require your own signing.",
        "tintColor": "#167D8D",
        "iconURL": icon_url,
        "apps": [],
        "news": [],
    }
    versions = []
    seen = set()
    for release in releases:
        for asset in release.get("assets", []):
            name = asset["name"]
            if not name.lower().endswith(".ipa"):
                continue
            if not IPA_NAME.fullmatch(name):
                if name.lower().startswith("cmanga"):
                    raise ValueError(f"Invalid CManga IPA name: {name}; expected cmanga-ios-VERSION+BUILD.ipa")
                print(f"Excluding non-CManga IPA: {name}", file=sys.stderr)
                continue
            entry = verified_ipa(repository, asset)
            identity = (entry["version"], entry["buildVersion"])
            if identity in seen:
                raise ValueError(f"Duplicate CManga iOS version/build in releases: {identity}")
            seen.add(identity)
            entry["date"] = release["published_at"]
            entry["localizedDescription"] = release.get("body") or "CManga release."
            versions.append(entry)
    if versions:
        versions.sort(key=lambda entry: (tuple(map(int, entry["version"].split("."))), int(entry["buildVersion"])), reverse=True)
        latest = versions[0]
        source["apps"].append({
            "name": "CManga",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": repository_info["owner"]["login"],
            "subtitle": "Comics, with local AI.",
            "localizedDescription": source["description"],
            "iconURL": icon_url,
            "tintColor": "#167D8D",
            "category": "books",
            "versions": versions,
            "version": latest["version"],
            "versionDate": latest["date"],
            "versionDescription": latest["localizedDescription"],
            "downloadURL": latest["downloadURL"],
            "size": latest["size"],
        })
    return source


def main():
    repository = configured_repository()
    repository_info = github_json(f"repos/{repository}")
    # Use GitHub's canonical casing for release URL checks and generated source URLs.
    repository = repository_info["full_name"]
    source = generate_source(repository, repository_info, fetch_releases(repository))
    Path(__file__).with_name("alt_store.json").write_text(
        json.dumps(source, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Generated CManga source from {repository}: {len(source['apps'])} published app(s).")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"CManga AltStore generation failed: {error}", file=sys.stderr)
        sys.exit(1)
