#!/bin/zsh
# Runs synthetic extension APIs in two temporary spaces. No accounts or existing browser data.
# Usage: zsh Validation/mac-extension-compatibility.sh /absolute/path/to/eGlu.app
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
source_app="${1:?Pass the absolute path to a built eGlu.app}"
scratch="$(mktemp -d /private/tmp/eglu-extension-compatibility.XXXXXX)"
python3 - "$repo" "$source_app" "$scratch" <<'PY'
from pathlib import Path
import plistlib, shutil, sys, uuid, zipfile
repo, source, scratch = map(Path, sys.argv[1:])
app = scratch / 'ExtensionValidation.app'
shutil.copytree(source, app)
file = app / 'Contents/Info.plist'
info = plistlib.loads(file.read_bytes())
info['CFBundleIdentifier'] = 'net.taehee.safience.validation.' + uuid.uuid4().hex
info['CFBundleName'] = 'Extension API Validation'
info['EGLU_DATA_ROOT'] = str(scratch / 'data')
file.write_bytes(plistlib.dumps(info))
with zipfile.ZipFile(scratch / 'fixture.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted((repo / 'Validation/Fixtures/extension-compatibility').iterdir()): archive.write(file, file.name)
PY
codesign --force --deep --sign - "$scratch/ExtensionValidation.app" >/dev/null
"$scratch/ExtensionValidation.app/Contents/MacOS/eGlu" -ApplePersistenceIgnoreState YES -writingAsked validation \
  -installExtension "$scratch/fixture.zip" -extensionID hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh \
  -extensionSpaces 2 -extensionPages 'chrome-extension://hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh/report.html' \
  -extensionUITest YES -extensionInspectPages YES -extensionReportWords YES \
  -extensionReport "$scratch/report.txt" -extensionWait 40 > "$scratch/app.log" 2>&1 &
validation_pid=$!
trap 'kill -TERM "$validation_pid" 2>/dev/null || true' EXIT
for attempt in {1..90}; do
  if [[ -f "$scratch/report.txt" ]]; then
    python3 - "$scratch/report.txt" <<'PY'
from pathlib import Path
import re, sys
file = Path(sys.argv[1])
text = file.read_text()
steps = Path(str(file) + '.steps').read_text()
results = re.findall(r'validation ([A-F0-9-]+): API fixture finished: (\d+)/(\d+)', steps)
assert len(results) == 2 and len({space for space, _, _ in results}) == 2, f'Missing results: {file}'
assert all(passed == total and int(total) >= 30 for _, passed, total in results), f'Failed checks: {file}'
for space, passed, total in results: print(f'Space {space}: {passed}/{total} live API checks passed')
print(f'Evidence: {file}')
PY
    exit 0
  fi
  sleep 1
done
print -u2 "Timed out. Diagnostics: $scratch"
exit 1
