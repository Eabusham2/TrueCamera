#!/usr/bin/env python3
"""Download the published release and verify its bytes, source and device package."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def github_json(endpoint):
    return json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-f]{40}", args.commit), "Expected a full source commit SHA")
    root = f"repos/{args.repository}"
    encoded_tag = quote(args.tag, safe="")
    release = github_json(f"{root}/releases/tags/{encoded_tag}")
    require(release.get("draft") is False, "Release is still a draft")
    require(release.get("tag_name") == args.tag, "Release tag differs from the requested tag")
    target = github_json(f"{root}/git/ref/tags/{encoded_tag}")["object"]
    for _ in range(8):
        if target.get("type") != "tag":
            break
        target = github_json(f"{root}/git/tags/{target['sha']}")["object"]
    require(target.get("type") == "commit" and target.get("sha") == args.commit,
            "Release tag does not resolve to the tested source commit")

    names = ["TrueCamera-unsigned.ipa", "TrueCamera-unsigned.ipa.sha256", "build-info.json"]
    assets = {}
    for name in names:
        matches = [asset for asset in release.get("assets", []) if asset.get("name") == name]
        require(len(matches) == 1, f"Missing or duplicate release asset: {name}")
        asset = matches[0]
        require(asset.get("state") == "uploaded" and asset.get("size", 0) > 0,
                f"Release asset has not finished uploading: {name}")
        require(bool(asset.get("browser_download_url")), f"Missing download URL: {name}")
        assets[name] = asset

    with tempfile.TemporaryDirectory(prefix="truecamera-release-") as temporary:
        folder = Path(temporary)
        command = ["gh", "release", "download", args.tag, "--repo", args.repository, "--dir", temporary]
        for name in names:
            command.extend(["--pattern", name])
        subprocess.run(command, check=True)
        for name in names:
            path = folder / name
            require(path.is_file() and path.stat().st_size == assets[name]["size"],
                    f"Downloaded asset size differs: {name}")
            advertised_digest = assets[name].get("digest")
            if advertised_digest:
                require(advertised_digest == "sha256:" + sha256(path),
                        f"Downloaded asset differs from GitHub digest: {name}")

        ipa = folder / names[0]
        checksum = (folder / names[1]).read_text().split()
        require(len(checksum) == 2 and checksum[1].lstrip("*") == names[0],
                "Checksum file does not identify the IPA")
        digest = sha256(ipa)
        require(checksum[0].lower() == digest, "Downloaded IPA failed its published SHA-256 checksum")
        info = json.loads((folder / "build-info.json").read_text())
        require(info.get("app") == "TrueCamera", "Unexpected app in build metadata")
        require(info.get("commit") == args.commit, "Build metadata source commit differs")
        require(str(info.get("run")) == args.run_id, "Build metadata workflow run differs")
        require(info.get("signed") is False, "Build metadata must identify an unsigned IPA")
        require(info.get("physical_aperture_api_compiled") is True,
                "Physical-aperture API support was not compiled")
        xcode = re.search(r"(?m)^Xcode (\d+)", info.get("xcode", ""))
        require(xcode and int(xcode.group(1)) >= 27, "Build used an older Xcode")
        require(int(info.get("sdk", "0").split(".")[0]) >= 27, "Build used an older iPhone SDK")
        require(info.get("minimum_iOS") == "17.0", "Unexpected minimum iOS target")
        subprocess.run([sys.executable, str(Path(__file__).with_name("verify_ipa.py")), str(ipa)], check=True)

        report = {
            "verified": True,
            "release": release["html_url"],
            "tag": args.tag,
            "commit": args.commit,
            "workflow_run": args.run_id,
            "ipa": assets[names[0]]["browser_download_url"],
            "ipa_bytes": ipa.stat().st_size,
            "sha256": digest,
            "assets_downloaded": names,
            "unsigned": True,
            "physical_aperture_api_compiled": True,
        }
        output = json.dumps(report, indent=2) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(output)
        print(output, end="")


if __name__ == "__main__":
    main()
