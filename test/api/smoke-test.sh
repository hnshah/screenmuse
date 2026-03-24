#!/usr/bin/env bash
# ScreenMuse API Smoke Test
# Runs a quick sanity check on all major endpoints.
# Requires ScreenMuse running on port 7823.
# Usage: ./test/api/smoke-test.sh [port]

PORT=${1:-7823}
BASE="http://localhost:$PORT"
PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

check() {
  local name="$1"
  local expected_status="$2"
  local method="$3"
  local path="$4"
  local body="$5"

  if [ -n "$body" ]; then
    response=$(curl -s -o /tmp/sm_resp.json -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Content-Type: application/json" -d "$body" 2>/dev/null)
  else
    response=$(curl -s -o /tmp/sm_resp.json -w "%{http_code}" -X "$method" "$BASE$path" 2>/dev/null)
  fi

  if [ "$response" = "$expected_status" ]; then
    echo -e "${GREEN}✅ PASS${NC} $name (HTTP $response)"
    PASS=$((PASS + 1))
  else
    echo -e "${RED}❌ FAIL${NC} $name — expected HTTP $expected_status, got $response"
    echo "   Response: $(cat /tmp/sm_resp.json | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ScreenMuse API Smoke Test — $BASE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Server Health ──────────────────────────────
echo ""
echo "Server Health"
check "GET /version" 200 GET /version
check "GET /status" 200 GET /status
check "GET /windows" 200 GET /windows
check "GET /recordings" 200 GET /recordings

# ── System State ───────────────────────────────
echo ""
echo "System State"
check "GET /system/clipboard" 200 GET /system/clipboard
check "GET /system/active-window" 200 GET /system/active-window
check "GET /system/running-apps" 200 GET /system/running-apps

# ── Version endpoint count ─────────────────────
echo ""
echo "Endpoint Count"
count=$(curl -s "$BASE/version" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('api_endpoints',[])))" 2>/dev/null)
if [ "$count" -ge 30 ] 2>/dev/null; then
  echo -e "${GREEN}✅ PASS${NC} Endpoint count: $count (≥30)"
  PASS=$((PASS + 1))
else
  echo -e "${RED}❌ FAIL${NC} Endpoint count: $count (expected ≥30)"
  FAIL=$((FAIL + 1))
fi

# ── Recording Lifecycle ────────────────────────
echo ""
echo "Recording Lifecycle"
check "POST /start (no body)" 200 POST /start '{}'
sleep 2
check "POST /chapter" 200 POST /chapter '{"name":"Test Chapter"}'
check "POST /note" 200 POST /note '{"text":"Smoke test note"}'
check "POST /highlight" 200 POST /highlight
check "POST /screenshot" 200 POST /screenshot
check "POST /frame" 200 POST /frame '{"format":"jpeg"}'
check "GET /status (recording)" 200 GET /status
check "POST /pause" 200 POST /pause
check "POST /resume" 200 POST /resume
check "POST /stop" 200 POST /stop
sleep 1

# ── Export (requires a completed recording) ────
echo ""
echo "Export (requires completed recording)"
check "POST /export (gif)" 200 POST /export '{"format":"gif","fps":5,"scale":400,"end":2}'
check "POST /trim" 200 POST /trim '{"start":0,"end":2}'
check "POST /speedramp" 200 POST /speedramp '{"idle_speed":4.0}'
check "GET /recordings (after recording)" 200 GET /recordings

# ── Window Management ──────────────────────────
echo ""
echo "Window Management"
check "POST /window/focus (invalid app)" 404 POST /window/focus '{"app":"__nonexistent_app_xyz__"}'
check "POST /window/position (no app)" 400 POST /window/position '{}'
check "POST /window/hide-others (invalid)" 404 POST /window/hide-others '{"app":"__nonexistent__"}'

# ── Error Handling ─────────────────────────────
echo ""
echo "Error Handling"
check "POST /start (already stopped)" 409 POST /start '{}' 2>/dev/null || true
check "POST /export (no video)" 404 POST /export '{"format":"gif"}' 2>/dev/null || true
check "POST /trim (invalid range)" 400 POST /trim '{"start":99,"end":1}'
check "DELETE /recording (not found)" 404 DELETE /recording '{"filename":"__nonexistent__.mp4"}'
check "POST /note (empty text)" 400 POST /note '{}'
check "POST /window/focus (missing app)" 400 POST /window/focus '{}'

# ── iCloud (best effort — may 503 if not configured) ──
echo ""
echo "iCloud (may 503 if iCloud not configured)"
icloud_status=$(curl -s -o /tmp/sm_resp.json -w "%{http_code}" -X POST "$BASE/upload/icloud" \
  -H "Content-Type: application/json" -d '{"source":"last"}' 2>/dev/null)
if [ "$icloud_status" = "200" ] || [ "$icloud_status" = "503" ] || [ "$icloud_status" = "404" ]; then
  echo -e "${GREEN}✅ PASS${NC} POST /upload/icloud (HTTP $icloud_status — expected 200/503/404)"
  PASS=$((PASS + 1))
else
  echo -e "${RED}❌ FAIL${NC} POST /upload/icloud — unexpected HTTP $icloud_status"
  FAIL=$((FAIL + 1))
fi

# ── Summary ────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}ALL PASSED${NC} — $PASS/$TOTAL tests"
  exit 0
else
  echo -e "${RED}FAILURES: $FAIL/$TOTAL${NC} — $PASS passed, $FAIL failed"
  exit 1
fi
