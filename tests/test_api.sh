#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────────
# API integration test suite for IPTVGrab Rust server
# Usage:
#   ./tests/test_api.sh               # starts server internally
#   BASE=http://192.168.1.10:8765 ./tests/test_api.sh  # against existing server
# ────────────────────────────────────────────────────────────────────────────────
set -uo pipefail

BASE="${BASE:-http://localhost:8765}"
SERVER_BIN="./target/debug/m3u8-server"
SERVER_PID=""
PASS=0
FAIL=0
PL_ID=""
CH_ID=""
GRP_ID=""

# ── Helpers ──────────────────────────────────────────────────────────────────

green() { echo -e "\033[32m✓\033[0m $*"; }
red()   { echo -e "\033[31m✗\033[0m $*"; }

assert_http() {
  local label="$1" expected="$2"
  local actual
  actual=$(echo "$RESPONSE" | grep "^HTTP_CODE:" | cut -d: -f2)
  if [[ "$actual" == "$expected" ]]; then
    green "$label (HTTP $actual)"
    ((PASS++))
  else
    red "$label — expected HTTP $expected, got HTTP $actual"
    red "  body: $(echo "$RESPONSE" | grep -v '^HTTP_CODE:')"
    ((FAIL++))
  fi
}

assert_json() {
  local label="$1" key="$2" expected="$3"
  local actual
  actual=$(echo "$RESPONSE" | grep -v '^HTTP_CODE:' | python3 -c \
    "import sys,json; d=json.load(sys.stdin); v=d.get('$key',''); print(str(v).lower() if isinstance(v,bool) else v)" 2>/dev/null || echo "")
  if [[ "$actual" == "$expected" ]]; then
    green "$label ($key=$actual)"
    ((PASS++))
  else
    red "$label — $key expected '$expected', got '$actual'"
    ((FAIL++))
  fi
}

assert_json_ne() {
  local label="$1" key="$2"
  local actual
  actual=$(echo "$RESPONSE" | grep -v '^HTTP_CODE:' | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('$key',''))" 2>/dev/null || echo "")
  if [[ -n "$actual" && "$actual" != "None" ]]; then
    green "$label ($key=$actual)"
    ((PASS++))
  else
    red "$label — $key is empty or None"
    ((FAIL++))
  fi
}

assert_json_list() {
  local label="$1" key="$2" min_len="$3"
  local actual
  actual=$(echo "$RESPONSE" | grep -v '^HTTP_CODE:' | python3 -c \
    "import sys,json; d=json.load(sys.stdin); arr=d.get('$key',d) if isinstance(d,dict) else d; print(len(arr) if isinstance(arr,list) else -1)" 2>/dev/null || echo "-1")
  if (( actual >= min_len )); then
    green "$label ($key len=$actual >= $min_len)"
    ((PASS++))
  else
    red "$label — $key list len=$actual < $min_len"
    ((FAIL++))
  fi
}

curl_api() {
  local method="$1" path="$2"
  shift 2
  RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X "$method" \
    -H "Content-Type: application/json" "$@" "$BASE$path")
}

extract() {
  echo "$RESPONSE" | grep -v '^HTTP_CODE:' | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$1',''))" 2>/dev/null || echo ""
}

# ── Server lifecycle ──────────────────────────────────────────────────────────

start_server() {
  if ! curl -s --max-time 1 "$BASE/api/auth/status" >/dev/null 2>&1; then
    if [[ ! -x "$SERVER_BIN" ]]; then
      echo "Building server..."
      cargo build -p server 2>/dev/null
    fi
    RUST_LOG=warn "$SERVER_BIN" &
    SERVER_PID=$!
    sleep 2
    if ! curl -s --max-time 2 "$BASE/api/auth/status" >/dev/null 2>&1; then
      echo "Server failed to start"; exit 1
    fi
    echo "Server started (PID $SERVER_PID)"
  else
    echo "Using existing server at $BASE"
  fi
}

stop_server() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
}
trap stop_server EXIT

# ════════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " IPTVGrab API Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
start_server

# ── Auth ─────────────────────────────────────────────────────────────────────
echo ""
echo "[ Auth ]"
curl_api GET /api/auth/status
assert_http "GET /api/auth/status" 200
assert_json "auth_required field" auth_required false

# ── Parse ─────────────────────────────────────────────────────────────────────
echo ""
echo "[ Parse ]"
curl_api POST /api/parse -d '{"url":""}'
assert_http "POST /api/parse (empty url)" 400

# ── Playlists CRUD ─────────────────────────────────────────────────────────────
echo ""
echo "[ Playlists CRUD ]"

# Use Python to build the JSON body safely (avoids embedded-quote issues in bash strings)
PL_BODY=$(python3 -c "
import json, sys
raw = '#EXTM3U\n#EXTINF:-1 group-title=\"News\",CNN\nhttp://example.com/cnn.m3u8\n#EXTINF:-1 group-title=\"Sports\",ESPN\nhttp://example.com/espn.m3u8\n#EXTINF:-1,BBC\nhttp://example.com/bbc.m3u8'
print(json.dumps({'name': 'TestList', 'raw': raw}))
")
curl_api POST /api/playlists -d "$PL_BODY"
assert_http "POST /api/playlists (raw)" 201
assert_json "playlist created with name" name TestList
PL_ID=$(extract id)
echo "  playlist_id=$PL_ID"

curl_api GET /api/playlists
assert_http "GET /api/playlists" 200

curl_api GET "/api/playlists/$PL_ID"
assert_http "GET /api/playlists/:id" 200
assert_json "playlist name" name TestList

curl_api PATCH "/api/playlists/$PL_ID" -d '{"name":"RenamedList"}'
assert_http "PATCH /api/playlists/:id" 200
assert_json "renamed" name RenamedList

curl_api POST "/api/playlists/$PL_ID/refresh"
assert_http "POST /api/playlists/:id/refresh (no URL → 400)" 400

# ── Channels ──────────────────────────────────────────────────────────────────
echo ""
echo "[ Channels ]"
curl_api GET /api/channels
assert_http "GET /api/channels" 200
assert_json_list "channels list" "" 1

# ── All-Playlists (merged view) ────────────────────────────────────────────────
echo ""
echo "[ All-Playlists ]"

curl_api GET /api/all-playlists
assert_http "GET /api/all-playlists" 200
assert_json_list "groups" groups 1

# Save merged config back (PUT) — write body to temp file to avoid bash interpolation of JSON
GROUPS_JSON_FILE=$(mktemp /tmp/m3u8test.XXXXXX)
echo "$RESPONSE" | grep -v '^HTTP_CODE:' | python3 -c \
  "import sys,json; d=json.load(sys.stdin); json.dump({'groups':d.get('groups',[])},sys.stdout)" \
  > "$GROUPS_JSON_FILE"
RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X PUT \
  -H "Content-Type: application/json" \
  --data-binary "@$GROUPS_JSON_FILE" "$BASE/api/all-playlists")
rm -f "$GROUPS_JSON_FILE"
assert_http "PUT /api/all-playlists" 200

# Add custom group
curl_api POST /api/all-playlists/groups -d '{"name":"MyCustomGroup"}'
assert_http "POST /api/all-playlists/groups" 201
GRP_ID=$(echo "$RESPONSE" | grep -v '^HTTP_CODE:' | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('group',{}).get('id',''))" 2>/dev/null || echo "")
echo "  group_id=$GRP_ID"

# Duplicate group name should fail
curl_api POST /api/all-playlists/groups -d '{"name":"MyCustomGroup"}'
assert_http "POST /api/all-playlists/groups (duplicate)" 400

# Add custom channel
curl_api POST /api/all-playlists/channels \
  -d "{\"group_id\":\"$GRP_ID\",\"name\":\"MyChannel\",\"url\":\"http://example.com/ch.m3u8\",\"tvg_logo\":\"\"}"
assert_http "POST /api/all-playlists/channels" 201
CH_ID=$(echo "$RESPONSE" | grep -v '^HTTP_CODE:' | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('channel',{}).get('id',''))" 2>/dev/null || echo "")
echo "  channel_id=$CH_ID"

# Edit channel
curl_api PATCH "/api/all-playlists/channels/$CH_ID" -d '{"enabled":false}'
assert_http "PATCH /api/all-playlists/channels/:id (disable)" 200

# Export M3U
curl_api GET /api/all-playlists/export.m3u
assert_http "GET /api/all-playlists/export.m3u" 200

# Delete custom channel
curl_api DELETE "/api/all-playlists/channels/$CH_ID"
assert_http "DELETE /api/all-playlists/channels/:id" 200

# Delete custom group
curl_api DELETE "/api/all-playlists/groups/$GRP_ID"
assert_http "DELETE /api/all-playlists/groups/:id" 200

# Delete sourced group should fail
SOURCED_GRP=$(echo "$GROUPS" | python3 -c \
  "import sys,json; gs=json.load(sys.stdin); print(next((g['id'] for g in gs if not g.get('custom')),''  ))" 2>/dev/null || echo "")
if [[ -n "$SOURCED_GRP" ]]; then
  curl_api DELETE "/api/all-playlists/groups/$SOURCED_GRP"
  assert_http "DELETE sourced group → 400" 400
fi

# Refresh all
curl_api POST /api/all-playlists/refresh
assert_http "POST /api/all-playlists/refresh" 200

# ── Health Check ──────────────────────────────────────────────────────────────
echo ""
echo "[ Health Check ]"

curl_api GET /api/health-check
assert_http "GET /api/health-check" 200
RUNNING=$(echo "$RESPONSE" | grep -v '^HTTP_CODE:' | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('state',{}).get('running',False))" 2>/dev/null || echo "")
if [[ "$RUNNING" == "False" ]]; then
  green "GET /api/health-check (state.running=false)"
  ((PASS++))
else
  red "GET /api/health-check — state.running expected False, got $RUNNING"
  ((FAIL++))
fi

curl_api POST /api/health-check
assert_http "POST /api/health-check (trigger)" 200
assert_json "health trigger ok" ok true

sleep 1
curl_api GET /api/health-check
assert_http "GET /api/health-check (after trigger)" 200
HEALTH_TOTAL=$(echo "$RESPONSE" | grep -v '^HTTP_CODE:' | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('state',{}).get('total',0))" 2>/dev/null || echo "0")
HEALTH_STARTED=$(echo "$RESPONSE" | grep -v '^HTTP_CODE:' | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('state',{}).get('started_at',0))" 2>/dev/null || echo "0")
if [[ "$HEALTH_TOTAL" != "0" && "$HEALTH_STARTED" != "0" && "$HEALTH_STARTED" != "0.0" ]]; then
  green "health state updated (total=$HEALTH_TOTAL started_at=$HEALTH_STARTED)"
  ((PASS++))
else
  red "health state did not update after trigger (total=$HEALTH_TOTAL started_at=$HEALTH_STARTED)"
  ((FAIL++))
fi

# ── Tasks ────────────────────────────────────────────────────────────────────
echo ""
echo "[ Tasks ]"

curl_api GET /api/tasks
assert_http "GET /api/tasks" 200

# Restart on non-existent task
curl_api POST /api/tasks/nonexistent/restart
assert_http "POST /api/tasks/nonexistent/restart → 404" 404

# ── Cleanup ──────────────────────────────────────────────────────────────────
echo ""
echo "[ Cleanup ]"
if [[ -n "$PL_ID" ]]; then
  curl_api DELETE "/api/playlists/$PL_ID"
  assert_http "DELETE /api/playlists/:id" 200
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
echo " Results: $PASS/$TOTAL passed"
if (( FAIL > 0 )); then
  echo " FAILED: $FAIL tests"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
else
  echo " All tests passed!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi
