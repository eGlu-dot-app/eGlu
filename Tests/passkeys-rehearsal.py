#!/usr/bin/env python3
"""eGlu's passkeys in the real app, on a test build's rehearsal.

Build a Debug test copy with a bundle identifier of its own, so its
preferences and WebKit data are apart from the real app's:

    xcodebuild build -project eGlu.xcodeproj -scheme "eGlu Mac" -configuration Debug \\
      -derivedDataPath build/dd PRODUCT_BUNDLE_IDENTIFIER=net.taehee.safience.passkeytest \\
      CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \\
      MAC_ENTITLEMENTS=Config/eGluMacLocal.entitlements

then

    python3 Tests/passkeys-rehearsal.py build/dd/Build/Products/Debug/eGlu.app
    python3 Tests/passkeys-rehearsal.py build/dd/Build/Products/Debug/eGlu.app --native

With `-passkeyRehearsal YES` (the first) the app puts its passkeys in pages
without Apple's entitlement and answers with credentials made up after the
same checks: no sheet, no real passkey. Tests/passkeys.html runs in it,
served here on three ports for its frames, and posts what it found. The last
check waits for a passkey picked from the list under the page's field, which
the app picks itself a second after showing it (`-passkeyRehearsalPick`);
with `--by-hand` it waits a minute for you to pick it. `--native` starts it
without the rehearsal, where the page must find WebKit's own
navigator.credentials, as in any build without the entitlement.

The test copy keeps its workspace in a folder of its own (EGLU_DATA_ROOT),
and the run stops at once if it has anything open in the real app's
folder (~/Library/Application Support/Safience). Its folder, its WebKit
data and its preferences are removed afterwards. Nothing here ships in
the app.
"""
import json
import os
import plistlib
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
reports = queue.Queue()


class Site(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def do_POST(self):
        if self.path != "/report":
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        reports.put(json.loads(body))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


def serve():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Site)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    app = Path(sys.argv[1]).resolve()
    native = "--native" in sys.argv[2:]
    bundle = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    if bundle == "net.taehee.safience":
        sys.exit("That is the real app's identifier: build a test copy (see the top of this file).")
    page, frames, third = serve(), serve(), serve()
    query = "expect=native&report=1" if native else f"other={frames.server_port}&third={third.server_port}&report=1"
    url = f"http://127.0.0.1:{page.server_port}/Tests/passkeys.html?{query}"
    data = tempfile.mkdtemp(prefix="eglu-passkeys-")
    arguments = [] if native else ["-passkeyRehearsal", "YES"]
    if not native and "--by-hand" not in sys.argv[2:]:
        arguments += ["-passkeyRehearsalPick", "YES"]
    subprocess.run(["open", "-n", "--env", f"EGLU_DATA_ROOT={data}", str(app), "--args", *arguments], check=True)
    failed = True
    try:
        time.sleep(4)
        # Never the real app's data: a copy started without its own folder
        # writes the real workspace.
        real = str(Path.home() / "Library/Application Support/Safience") + "/"
        pids = subprocess.run(["pgrep", "-f", str(app / "Contents/MacOS")], capture_output=True, text=True).stdout.split()
        if not pids:
            sys.exit("The test copy didn't start.")
        for pid in pids:
            opened = subprocess.run(["lsof", "-p", pid], capture_output=True, text=True).stdout
            if real in opened:
                sys.exit(f"The test copy has the real app's folder open ({real}): stopped.")
        subprocess.run(["open", "-a", str(app), url], check=True)
        last, deadline = None, time.time() + 120
        while time.time() < deadline:
            try:
                last = reports.get(timeout=1)
            except queue.Empty:
                continue
            if last.get("done"):
                break
        if last is None:
            print("No report from the page.")
        else:
            for result in last["results"]:
                print(("ok  " if result["ok"] else "NO  ") + result["name"] + (f": {result['detail']}" if result["detail"] else ""))
            failed = not last.get("done") or not all(r["ok"] for r in last["results"])
            print("FAILED" if failed else "PASSED")
    finally:
        subprocess.run(["pkill", "-f", str(app / "Contents/MacOS")])
        time.sleep(1)
        shutil.rmtree(data, ignore_errors=True)
        shutil.rmtree(Path.home() / "Library/WebKit" / bundle, ignore_errors=True)
        subprocess.run(["defaults", "delete", bundle], capture_output=True)
        (Path.home() / "Library/Preferences" / f"{bundle}.plist").unlink(missing_ok=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
