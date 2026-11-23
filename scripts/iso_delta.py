#!/usr/bin/env python3
"""Publish or rebuild an ISO using independently reusable, content-defined chunks."""
import argparse
from bisect import bisect_right
from contextlib import nullcontext
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import subprocess
import tempfile
import time
from http.client import HTTPException, IncompleteRead
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener, urlopen


FORMAT = "vitreus-iso-delta-v1"
MIB = 1024 * 1024
PART_LIMIT = 1900 * MIB
REQUEST_LIMIT = 16 * MIB
CHUNK_MIN = 32 * 1024
CHUNK_MAX = 512 * 1024
MARKER = b"\x94\x27"
HEX_DIGEST = re.compile(r"[0-9a-f]{64}")


def chunks(stream):
    """Cut at a byte marker so insertions can shift offsets without shifting every chunk."""
    tail = b""
    while True:
        block = stream.read(4 * MIB)
        data = tail + block
        pos = 0
        while len(data) - pos >= CHUNK_MAX or (not block and pos < len(data)):
            limit = min(pos + CHUNK_MAX, len(data))
            marker = data.find(MARKER, pos + CHUNK_MIN, limit)
            end = marker + len(MARKER) if marker >= 0 else limit
            yield data[pos:end]
            pos = end
        if not block:
            return
        tail = data[pos:]


def safe_name(name):
    if not isinstance(name, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", name):
        raise ValueError("Asset names must use ASCII letters, digits, dots, hyphens or underscores")
    return name


def web_url(source):
    return urlsplit(str(source)).scheme in ("https", "http")


def pack(source, dest, base_url=None, part_limit=PART_LIMIT):
    name = safe_name(source.name)
    if not name.endswith(".iso") or not source.stat().st_size:
        raise ValueError("Supply a nonempty .iso file")
    if base_url and not web_url(base_url):
        raise ValueError("--base-url must be an HTTP(S) directory URL")
    dest.mkdir(exist_ok=True, parents=True)
    if any(dest.iterdir()):
        raise ValueError(f"Use an empty directory for release assets: {dest}")
    split = source.stat().st_size > part_limit
    full_hash = hashlib.sha256()
    total = 0
    parts = []
    sink = None
    try:
        with source.open("rb") as original:
            for data in chunks(original):
                if not parts or part_size + len(data) > part_limit:
                    if sink:
                        sink.close()
                    part_name = f"{name}.part{len(parts) + 1:03d}" if split else name
                    parts.append({"name": part_name, "chunks": []})
                    sink = (dest / part_name).open("xb") if split else None
                    part_size = 0
                full_hash.update(data)
                parts[-1]["chunks"].append((len(data), hashlib.sha256(data).hexdigest()))
                if sink:
                    sink.write(data)
                total += len(data)
                part_size += len(data)
    finally:
        if sink:
            sink.close()
    if not split:
        try:
            os.link(source, dest / name)
        except OSError:
            shutil.copyfile(source, dest / name)
    digest = full_hash.hexdigest()
    index = {"format": FORMAT, "name": name, "size": total, "sha256": digest, "parts": parts}
    if base_url:
        index["base_url"] = base_url.rstrip("/") + "/"
    (dest / "iso-index.json").write_text(json.dumps(index, separators=(",", ":")) + "\n")
    (dest / "SHA256SUMS").write_text(f"{digest}  {name}\n")
    shutil.copyfile(__file__, dest / "iso_delta.py")
    print(f"Indexed {total:,} bytes in {len(parts)} asset(s). SHA-256 {digest}")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHubRelease:
    """Only send GitHub credentials to api.github.com. Fetch signed assets separately."""

    def __init__(self, repo, tag):
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo, re.ASCII) or any(
            part in (".", "..") for part in repo.split("/")
        ):
            raise ValueError("--repo must be OWNER/REPOSITORY")
        self.api_root = f"https://api.github.com/repos/{repo}/releases/"
        self.api = build_opener(NoRedirect())
        self.token = os.getenv("GH_TOKEN") or os.getenv("GITHUB_TOKEN")
        if not self.token and shutil.which("gh"):
            auth = subprocess.run(["gh", "auth", "token", "--hostname", "github.com"],
                                  capture_output=True, text=True)
            if auth.returncode == 0:
                self.token = auth.stdout.strip()
        self.signed_urls = {}
        path = "tags/" + quote(tag, safe="") if tag else "latest"
        try:
            with self.api_request(path, "application/vnd.github+json") as response:
                release = json.load(response)
        except HTTPError as error:
            if error.code in (401, 403, 404):
                raise ValueError("Release unavailable. Check the tag and run gh auth login "
                                 "or set GH_TOKEN with read access to the repository.") from error
            raise
        self.assets = {entry["name"]: int(entry["id"]) for entry in release["assets"]}

    def api_request(self, path, media_type, headers=None):
        headers = dict(headers or {}, Accept=media_type)
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = Request(self.api_root + path, headers=headers)
        return self.api.open(request, timeout=120)

    def open_asset(self, name, headers=None):
        if name not in self.assets:
            raise ValueError(f"Release asset not found: {name}")
        if name in self.signed_urls:
            try:
                return urlopen(Request(self.signed_urls[name], headers=headers or {}), timeout=120)
            except HTTPError as error:
                if error.code not in (401, 403, 404, 410, 618):
                    raise
                error.close()
                del self.signed_urls[name]
        # GitHub can stream directly, or issue a short-lived signed URL. Bust
        # stale cached redirects when refreshing an expired signed URL.
        path = f"assets/{self.assets[name]}?t={time.time_ns()}"
        try:
            return self.api_request(path, "application/octet-stream", headers)
        except HTTPError as redirect:
            if redirect.code not in (301, 302, 303, 307, 308):
                raise
            location = redirect.headers.get("Location", "")
            redirect.close()
        target = urlsplit(location)
        if target.scheme != "https" or not target.netloc or target.username or target.password:
            raise ValueError("Invalid signed release asset URL")
        self.signed_urls[name] = location
        return urlopen(Request(location, headers=headers or {}), timeout=120)


def load_index(source):
    if isinstance(source, GitHubRelease):
        with source.open_asset("iso-index.json") as response:
            index = json.load(response)
        base = source
    elif web_url(source):
        with urlopen(source, timeout=60) as response:
            index = json.load(response)
            resolved = response.geturl()
        # GitHub redirects to a signed single-file URL. Sibling asset links use
        # the release directory, never the signed attachment host.
        base = index.get("base_url") or urljoin(source, "./")
        if not web_url(base):
            raise ValueError(f"Invalid asset URL in index from {urlsplit(resolved).hostname}")
    else:
        path = Path(source)
        index = json.loads(path.read_bytes())
        base = path.resolve().parent
    if index["format"] != FORMAT:
        raise ValueError("Unsupported ISO index version")
    safe_name(index["name"])
    if not HEX_DIGEST.fullmatch(index["sha256"]):
        raise ValueError("Invalid image checksum")
    total = 0
    for part in index["parts"]:
        safe_name(part["name"])
        if not part["chunks"]:
            raise ValueError("Empty asset in index")
        for size, digest in part["chunks"]:
            if type(size) is not int or not 0 < size <= CHUNK_MAX or not HEX_DIGEST.fullmatch(digest):
                raise ValueError("Invalid chunk in index")
            total += size
    if not total or total != index["size"]:
        raise ValueError("Invalid image size")
    return index, base


def read_range(base, name, start, length, part_size):
    if isinstance(base, Path):
        with (base / name).open("rb") as asset:
            asset.seek(start)
            data = asset.read(length)
    else:
        end = start + length - 1
        headers = {"Range": f"bytes={start}-{end}", "Accept-Encoding": "identity"}
        for attempt in range(3):
            try:
                if isinstance(base, GitHubRelease):
                    stream = base.open_asset(name, headers)
                else:
                    stream = urlopen(Request(urljoin(base, name), headers=headers), timeout=120)
                with stream as response:
                    expected = f"bytes {start}-{end}/{part_size}"
                    full_asset = response.status == 200 and start == 0 and length == part_size
                    if not full_asset and (response.status != 206 or response.headers.get("Content-Range") != expected):
                        raise ValueError("Server did not honor the requested byte range. Use the direct release URL.")
                    data = response.read(length + 1)
                    if len(data) != length:
                        raise OSError("Incomplete byte range")
                break
            except (URLError, OSError, IncompleteRead) as error:
                if attempt == 2:
                    raise
                print(f"Retrying asset range after {error}", file=sys.stderr)
                time.sleep(2 ** attempt)
    if len(data) != length:
        raise ValueError(f"Incomplete range from {name}")
    return data


def seed_offsets(seed):
    offsets = {}
    if seed is not None:
        print("Indexing the local seed…", file=sys.stderr, flush=True)
        offset = 0
        for data in chunks(seed):
            offsets.setdefault(hashlib.sha256(data).hexdigest(), offset)
            offset += len(data)
    return offsets


def reconstruct(index, base, seed, dest, old_chunks):
    reused = 0
    actual_hash = hashlib.sha256()
    for part in index["parts"]:
        name = part["name"]
        items = part["chunks"]
        # Prefix sums let us bound a network request by both the next reusable
        # chunk and the request size, and translate chunk positions to byte ranges.
        starts = [0]
        for size, _ in items:
            starts.append(starts[-1] + size)
        i = 0
        while i < len(items):
            size, digest = items[i]
            if digest in old_chunks:
                seed.seek(old_chunks[digest])
                data = seed.read(size)
                reused += size
                stop = i + 1
            else:
                limit = bisect_right(starts, starts[i] + REQUEST_LIMIT) - 1
                stop = i + 1
                while stop < limit and items[stop][1] not in old_chunks:
                    stop += 1
                data = read_range(base, name, starts[i], starts[stop] - starts[i], starts[-1])
            actual_hash.update(data)
            dest.write(data)
            i = stop
    if actual_hash.hexdigest() != index["sha256"]:
        raise ValueError("SHA-256 mismatch. The assembled ISO was discarded.")
    return reused


def fetch(source, seed_path, output):
    index, base = load_index(source)
    output = output or Path(index["name"])
    if output.exists() and (not seed_path or not output.samefile(seed_path)):
        raise ValueError(f"Output exists. Choose a new path or explicitly pass it as --seed: {output}")
    temp = None
    try:
        with seed_path.open("rb") if seed_path else nullcontext(None) as seed:
            offsets = seed_offsets(seed)
            with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".iso-update-", delete=False) as dest:
                temp = Path(dest.name)
                reused = reconstruct(index, base, seed, dest, offsets)
        # This also allows the old ISO to be replaced in place after verification.
        os.replace(temp, output)
    finally:
        if temp:
            temp.unlink(missing_ok=True)
    print(f"Verified {output} (SHA-256 {index['sha256']}).")
    print(f"Reused {reused:,} bytes. Read {index['size'] - reused:,} ISO bytes from release assets.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    publish = commands.add_parser("pack", help="prepare a release directory")
    publish.add_argument("iso", type=Path)
    publish.add_argument("directory", type=Path)
    publish.add_argument("--base-url", help="immutable HTTP(S) directory containing the assets")
    update = commands.add_parser("fetch", help="assemble and verify an ISO")
    update.add_argument("index", nargs="?", help="URL or local path to iso-index.json")
    update.add_argument("--repo", help="GitHub OWNER/REPOSITORY (supports private releases)")
    update.add_argument("--tag", help="release tag for --repo (default: latest published release)")
    update.add_argument("--seed", type=Path, help="reuse matching bytes from an existing ISO")
    update.add_argument("--output", type=Path, help="target path (default: ISO name from index)")
    args = parser.parse_args()
    if args.command == "pack":
        pack(args.iso, args.directory, args.base_url)
    else:
        if bool(args.index) == bool(args.repo) or (args.tag and not args.repo):
            parser.error("Use an index URL/path or --repo OWNER/REPOSITORY [--tag TAG]")
        source = GitHubRelease(args.repo, args.tag) if args.repo else args.index
        fetch(source, args.seed, args.output)


if __name__ == "__main__":
    try:
        main()
    except (OSError, URLError, HTTPException, KeyError, TypeError, ValueError) as exc:
        sys.exit(str(exc))
