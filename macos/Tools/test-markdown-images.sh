#!/usr/bin/env bash
# Render real images in paragraphs and table cells, without credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
TASK_OUTPUT="${1:-$(mktemp -d /tmp/gitrochi-markdown-images.XXXXXX)}"
TASK_SERVER=""
trap 'if [[ -n "$TASK_SERVER" ]]; then kill "$TASK_SERVER" 2>/dev/null || true; wait "$TASK_SERVER" 2>/dev/null || true; fi; rm -rf "$TASK_TMP"' EXIT
mkdir -p "$TASK_OUTPUT"
python3 -u - "$TASK_TMP" <<'PY' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json, struct, sys, zlib
target = Path(sys.argv[1])
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
rows = b''.join(b'\0' + b'\xf0\x22\x22\xff' * 160 + b'\x22\x55\xf0\xff' * 160 for _ in range(160))
image = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', 320, 160, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with (target / 'requests.jsonl').open('a') as output:
            output.write(json.dumps(dict(self.headers)) + '\n')
        self.send_response(200)
        self.send_header('Content-Type', 'image/png')
        self.send_header('Content-Length', str(len(image)))
        self.end_headers()
        self.wfile.write(image)
    def log_message(self, *args): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(target / 'endpoint').write_text('http://127.0.0.1:' + str(server.server_port))
server.serve_forever()
PY
TASK_SERVER="$!"
for _ in {1..40}; do [[ -s "$TASK_TMP/endpoint" ]] && break; sleep 0.05; done
[[ -s "$TASK_TMP/endpoint" ]] || { echo "Image fixture server failed to start" >&2; exit 1; }
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    "$ROOT/Sources/Core/Markdown.swift" "$ROOT/Sources/Core/MarkdownInline.swift" \
    "$ROOT/Sources/Core/Models.swift" "$ROOT/Sources/Core/ProjectTaskReference.swift" \
    "$ROOT/Sources/Views/Shared/MarkdownView.swift" \
    "$ROOT/Tools/fixtures/MarkdownImages.swift" -o "$TASK_TMP/markdown-images"
"$TASK_TMP/markdown-images" "$TASK_OUTPUT" "$(cat "$TASK_TMP/endpoint")"
python3 - "$TASK_TMP/requests.jsonl" <<'PY'
import json, sys
requests = [json.loads(line) for line in open(sys.argv[1])]
assert requests, 'Images were never requested'
assert all(not {'authorization', 'cookie', 'private-token'} & {key.lower() for key in request} for request in requests), 'Image request carried credentials'
print('PASS: image requests contain no account credentials or cookies')
PY
