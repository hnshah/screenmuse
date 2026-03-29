#!/usr/bin/env bash
# ScreenMuse API Connectivity Checker
# Quick diagnostic — tests if the HTTP API is up and accessible.
# Usage: ./scripts/check-api.sh [port]

PORT=${1:-7823}
BASE="http://localhost:$PORT"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ScreenMuse API Connectivity Check"
echo "Target: $BASE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Check if something is listening on port 7823
echo ""
echo "${BOLD}1. Port Check${NC}"
if lsof -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
  echo -e "${GREEN}✅ Port $PORT has a listener${NC}"
  lsof -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | tail -1
else
  echo -e "${RED}❌ Nothing listening on port $PORT${NC}"
  echo "   → ScreenMuse is not running, or the NWListener failed to start."
  echo "   → Check Console.app for 'NWListener failed' messages."
  exit 1
fi

# 2. /health (no auth required)
echo ""
echo "${BOLD}2. Health Check (no auth)${NC}"
health_resp=$(curl -s -o /tmp/sm_health.json -w "%{http_code}" "$BASE/health" 2>/dev/null)
if [ "$health_resp" = "200" ]; then
  listener_state=$(cat /tmp/sm_health.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('listener','unknown'))" 2>/dev/null)
  version=$(cat /tmp/sm_health.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('version','?'))" 2>/dev/null)
  echo -e "${GREEN}✅ /health → 200 OK${NC} (version=$version, listener=$listener_state)"
  if [ "$listener_state" != "ready" ]; then
    echo -e "${YELLOW}⚠️  Listener state is '$listener_state', not 'ready' — connections may not be accepted${NC}"
  fi
else
  echo -e "${RED}❌ /health → HTTP $health_resp${NC}"
  cat /tmp/sm_health.json
  exit 1
fi

# 3. API key check
echo ""
echo "${BOLD}3. API Key${NC}"
API_KEY=""
if [ "${SCREENMUSE_NO_AUTH:-}" = "1" ]; then
  echo "ℹ️  Auth disabled (SCREENMUSE_NO_AUTH=1)"
elif [ -n "${SCREENMUSE_API_KEY:-}" ]; then
  API_KEY="$SCREENMUSE_API_KEY"
  echo "✅ API key from SCREENMUSE_API_KEY env var: ${API_KEY:0:8}…"
elif [ -f "$HOME/.screenmuse/api_key" ]; then
  API_KEY=$(cat "$HOME/.screenmuse/api_key" | tr -d '[:space:]')
  echo "✅ API key from ~/.screenmuse/api_key: ${API_KEY:0:8}…"
else
  echo -e "${RED}❌ No API key found${NC}"
  echo "   → ~/.screenmuse/api_key is missing"
  echo "   → Set SCREENMUSE_API_KEY env var, or launch ScreenMuse to auto-generate the key"
  echo "   → Or set SCREENMUSE_NO_AUTH=1 if the server has auth disabled"
fi

# 4. Authenticated request
if [ -n "$API_KEY" ]; then
  echo ""
  echo "${BOLD}4. Authenticated Request${NC}"
  auth_resp=$(curl -s -o /tmp/sm_status.json -w "%{http_code}" \
    -H "X-ScreenMuse-Key: $API_KEY" "$BASE/status" 2>/dev/null)
  if [ "$auth_resp" = "200" ]; then
    recording=$(cat /tmp/sm_status.json | python3 -c "import sys,json; d=json.load(sys.stdin); print('YES' if d.get('recording') else 'no')" 2>/dev/null)
    echo -e "${GREEN}✅ GET /status → 200 OK${NC} (recording=$recording)"
  elif [ "$auth_resp" = "401" ]; then
    echo -e "${RED}❌ GET /status → 401 Unauthorized${NC}"
    echo "   → API key mismatch. The server's key may have changed."
    echo "   → Check ~/.screenmuse/api_key matches what the server generated at launch."
    echo "   → Console.app will show 'ScreenMuse API key:' on startup."
  else
    echo -e "${RED}❌ GET /status → HTTP $auth_resp${NC}"
    cat /tmp/sm_status.json
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done."
