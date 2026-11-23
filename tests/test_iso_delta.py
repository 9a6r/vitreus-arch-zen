from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
from pathlib import Path
import random
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import iso_delta as delta


class UpdateTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.old = self.root / "old.iso"
        self.iso = self.root / "new.iso"
        self.output = self.root / "output.iso"
        self.release = self.root / "release"
        rng = random.Random(123)
        old = rng.getrandbits(16 * delta.MIB * 8).to_bytes(16 * delta.MIB, "big")
        # An unaligned insertion shifts all later offsets.
        self.old.write_bytes(old)
        self.iso.write_bytes(old[:2 * delta.MIB] + b"new wallpaper" * 117 +
                             old[2 * delta.MIB:8 * delta.MIB] + old[8 * delta.MIB + 71:])
        delta.pack(self.iso, self.release, "https://example.invalid/release/", part_limit=3 * delta.MIB)
        self.index = self.release / "iso-index.json"

    def test_offline_and_in_place(self):
        self.assertGreater(len(list(self.release.glob("*.part*"))), 1)
        delta.fetch(str(self.index), None, self.output)
        self.assertEqual(self.output.read_bytes(), self.iso.read_bytes())
        delta.fetch(str(self.index), self.old, self.old)
        self.assertEqual(self.old.read_bytes(), self.iso.read_bytes())

    def test_failure_preserves_old_iso(self):
        part = next(self.release.glob("*.part*"))
        part.write_bytes(b"broken")
        original = self.output.read_bytes() if self.output.exists() else b"my other ISO"
        self.output.write_bytes(original)
        with self.assertRaises(ValueError):
            delta.fetch(str(self.index), self.output, self.output)
        self.assertEqual(self.output.read_bytes(), original)
        self.assertFalse(list(self.root.glob(".iso-update-*")))

    def test_http_only_requests_missing_bytes(self):
        release = self.release
        index = json.loads(self.index.read_bytes())
        del index["base_url"]
        self.index.write_text(json.dumps(index))
        downloaded = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                data = (release / self.path[1:]).read_bytes()
                if self.path == "/iso-index.json":
                    self.send_response(200)
                else:
                    first, last = map(int, self.headers["Range"][6:].split("-"))
                    downloaded.append(last - first + 1)
                    self.send_response(206)
                    self.send_header("Content-Range", f"bytes {first}-{last}/{len(data)}")
                    data = data[first:last + 1]
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def log_message(self, *args):
                pass
        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            worker = threading.Thread(target=server.serve_forever)
            worker.start()
            try:
                url = f"http://127.0.0.1:{server.server_port}/iso-index.json"
                delta.fetch(url, self.old, self.output)
                self.assertGreater(sum(downloaded), 0)
                self.assertLess(sum(downloaded), self.iso.stat().st_size // 5)
                print("HTTP fixture transferred", sum(downloaded), "of", self.iso.stat().st_size, "bytes")
                self.assertEqual(self.output.read_bytes(), self.iso.read_bytes())
                downloaded.clear()
                delta.fetch(url, self.output, self.output)
                self.assertEqual(downloaded, [])
            finally:
                server.shutdown()
                worker.join()

    def test_private_auth_never_sent_to_asset_cdn_and_refreshes(self):
        requests = []
        def api_open(req, timeout):
            self.assertEqual(req.get_header("Authorization"), "Bearer test-token")
            self.assertTrue(req.full_url.startswith("https://api.github.com/repos/owner/repo/releases/"))
            if not "/assets/" in req.full_url:
                self.assertIn("/tags/v1", req.full_url)
                return io.BytesIO(b'{"assets": [{"name": "asset", "id": 12}]}')
            location = f"https://private-assets.invalid/link-{len(requests)}"
            requests.append(req)
            raise HTTPError(req.full_url, 302, "Found", {"Location": location}, io.BytesIO())
        visited = []
        def cdn(req, timeout):
            self.assertIsNone(req.get_header("Authorization"))
            self.assertEqual(req.get_header("Range"), "bytes=1-2")
            visited.append(req.full_url)
            if len(visited) == 2:
                raise HTTPError(req.full_url, 403, "Expired", {}, io.BytesIO())
            return io.BytesIO(b"ok")
        with patch.dict("os.environ", {"GH_TOKEN": "test-token"}), \
             patch.object(delta, "build_opener") as opener, patch.object(delta, "urlopen", cdn):
            opener.return_value.open.side_effect = api_open
            release = delta.GitHubRelease("owner/repo", "v1")
            for _ in range(3):
                with release.open_asset("asset", {"Range": "bytes=1-2"}) as result:
                    self.assertEqual(result.read(), b"ok")
        self.assertEqual(len(requests), 2)
        self.assertEqual(visited[0], visited[1])
        self.assertNotEqual(visited[1], visited[2])
        self.assertEqual(visited[2], visited[3])


if __name__ == "__main__":
    unittest.main()

