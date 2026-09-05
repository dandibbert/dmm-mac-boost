#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
python3 -m http.server 18765 --bind 127.0.0.1 --directory Sources/Pagekeep/Resources > dist/fixture-main.log 2>&1 &
P1=$!
python3 -m http.server 18766 --bind 127.0.0.1 --directory Sources/Pagekeep/Resources > dist/fixture-cross-origin.log 2>&1 &
P2=$!
trap 'kill "$P1" "$P2" 2>/dev/null || true' EXIT
export PAGEKEEP_TEST_OUTPUT="$PWD/dist"
python3 - <<'PY'
import pathlib, subprocess, urllib.request, time
for port in (18765, 18766):
    for _ in range(30):
        try:
            urllib.request.urlopen(f'http://127.0.0.1:{port}/Frame.html', timeout=1).close()
            break
        except OSError: time.sleep(.2)
    else: raise SystemExit(f'fixture server {port} failed')
with open('dist/smoke.log', 'w') as output:
    result = subprocess.run(['dist/Pagekeep.app/Contents/MacOS/Pagekeep', '--smoke-test'], stdout=output, stderr=subprocess.STDOUT, timeout=120)
print(pathlib.Path('dist/smoke.log').read_text())
raise SystemExit(result.returncode)
PY
