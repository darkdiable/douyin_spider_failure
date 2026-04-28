#!/bin/bash

set -e

OUTPUT_DIR="/app/GSB-Dogfood-VidSpider/douyinOutput"
REWARD_FILE="/logs/verifier/reward.txt"
TEST_PORT=9999

PYTHON_CLEAN=""

for PY_BIN in /usr/bin/python3.real /usr/bin/python.real /usr/bin/python3.10.real; do
    if [ -f "$PY_BIN" ] && [ -x "$PY_BIN" ]; then
        if timeout 2 "$PY_BIN" -c "import socket; s = socket.socket(); s.close(); print('OK')" 2>&1 | grep -q "OK"; then
            PYTHON_CLEAN="$PY_BIN"
            break
        fi
    fi
done

if [ -z "$PYTHON_CLEAN" ]; then
    for PY_BIN in /usr/bin/python3 /usr/bin/python python3 python; do
        if command -v "$PY_BIN" >/dev/null 2>&1; then
            if [ -f "$PY_BIN" ] && grep -q "restricted\|_SysConfig\|python3_sys_opt" "$PY_BIN" 2>/dev/null; then
                continue
            fi
            if timeout 2 "$PY_BIN" -c "import socket; s = socket.socket(); s.close(); print('OK')" 2>&1 | grep -q "OK"; then
                PYTHON_CLEAN="$PY_BIN"
                break
            fi
        fi
    done
fi

PYTHON_CLEAN=${PYTHON_CLEAN:-python3}

echo "0" > "$REWARD_FILE"

mkdir -p "$(dirname "$REWARD_FILE")" "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"/* 2>/dev/null || true

if command -v apt-get &> /dev/null; then
    apt-get update && apt-get install -y --no-install-recommends curl lsof netcat-openbsd ca-certificates 2>/dev/null || true
fi

start_test_server() {
    lsof -Pi :${TEST_PORT} -sTCP:LISTEN -t 2>/dev/null | xargs kill -9 2>/dev/null || true
    sleep 0.5
    
    echo -n -e '\x00\x00\x00\x18\x66\x74\x79\x70\x6d\x70\x34\x32' > /tmp/test_video.mp4
    echo -n -e '\x00\x00\x00\x00\x6d\x70\x34\x32\x69\x73\x6f\x6d' >> /tmp/test_video.mp4
    dd if=/dev/zero bs=1024 count=256 >> /tmp/test_video.mp4 2>/dev/null
    
    cat > /tmp/test_page.html << 'EOF'
<!DOCTYPE html>
<html><head><meta property="og:title" content="Test"></head>
<body><video src="/test_video.mp4"></video>
<script type="application/json" id="RENDER_DATA">
{"aweme_detail":{"video":{"play_addr":{"url_list":["http://LOCALHOST_TOKEN/test_video.mp4"]}}}}
</script></body></html>
EOF
    sed -i "s/LOCALHOST_TOKEN/localhost:${TEST_PORT}/g" /tmp/test_page.html
    
    cd /tmp
    "$PYTHON_CLEAN" -c "
import http.server
import socketserver
import os
PORT = ${TEST_PORT}
class TestHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.path = '/test_page.html' if self.path == '/' else self.path
        return http.server.SimpleHTTPRequestHandler.do_GET(self)
    def log_message(self, fmt, *args): pass
os.chdir('/tmp')
with socketserver.TCPServer(('', PORT), TestHandler) as httpd:
    httpd.serve_forever()
" > /dev/null 2>&1 &
    echo $! > /tmp/test_server.pid
    
    for i in {1..15}; do
        curl -s --connect-timeout 1 "http://localhost:${TEST_PORT}/test_video.mp4" 2>/dev/null | head -4 | grep -q "ftyp" && break
        sleep 0.3
    done
}

stop_test_server() {
    [ -f /tmp/test_server.pid ] && kill $(cat /tmp/test_server.pid 2>/dev/null) 2>/dev/null || true
    rm -f /tmp/test_server.pid /tmp/test_video.mp4 /tmp/test_page.html 2>/dev/null || true
}

start_test_server

cd /app/GSB-Dogfood-VidSpider/douyin_spider
python3 -m scrapy crawl douyin -a url="http://localhost:${TEST_PORT}/" > /tmp/crawl_log.txt 2>&1 || true

stop_test_server

VIDEO_FILE=$(find "$OUTPUT_DIR" -type f -name "*.mp4" -size +10k 2>/dev/null | head -1)

if [ -n "$VIDEO_FILE" ]; then
    echo "1" > "$REWARD_FILE"
else
    echo "0" > "$REWARD_FILE"
fi

rm -f /tmp/crawl_log.txt /tmp/test_server.log 2>/dev/null || true

exit 0