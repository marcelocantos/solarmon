#!/bin/bash
# Copyright 2026 Marcelo Cantos
# SPDX-License-Identifier: Apache-2.0
#
# solarmon — monitor GoodWe inverters via ping + SEMS API.
# Sends push notifications via Pushover when inverters go offline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SOLARMON_CONFIG:-$SCRIPT_DIR/config.json}"
STATE_FILE="${SOLARMON_STATE:-$SCRIPT_DIR/.state.json}"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: Config file not found: $CONFIG" >&2
    echo "Copy config.example.json to config.json and fill in your details." >&2
    exit 1
fi

read_config() { jq -r "$1" "$CONFIG"; }

PUSHOVER_USER="$(read_config '.pushover_user')"
PUSHOVER_TOKEN="$(read_config '.pushover_token')"
SEMS_ACCOUNT="$(read_config '.sems_account // empty')"
SEMS_PASSWORD="$(read_config '.sems_password // empty')"
PING_TIMEOUT="$(read_config '.ping_timeout // 5')"
PING_COUNT="$(read_config '.ping_count // 3')"

# Read inverters array
INVERTER_COUNT="$(jq '.inverters | length' "$CONFIG")"

# ---------------------------------------------------------------------------
# State management — track per-inverter alert state to avoid spam
# ---------------------------------------------------------------------------

init_state() {
    if [ ! -f "$STATE_FILE" ]; then
        echo '{}' > "$STATE_FILE"
    fi
}

get_state() {
    local key="$1"
    jq -r ".\"$key\" // \"ok\"" "$STATE_FILE"
}

set_state() {
    local key="$1" value="$2"
    local tmp="${STATE_FILE}.tmp"
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$STATE_FILE" > "$tmp" \
        && mv "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

notify() {
    local title="$1" message="$2" priority="${3:-1}"
    curl -s \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "title=$title" \
        --form-string "message=$message" \
        --form-string "priority=$priority" \
        "https://api.pushover.net/1/messages.json" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Ping check
# ---------------------------------------------------------------------------

check_ping() {
    local name="$1" ip="$2"

    if [ -z "$ip" ] || [ "$ip" = "null" ]; then
        return 0  # No IP configured, skip ping check.
    fi

    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" >/dev/null 2>&1; then
        echo "  PING $name ($ip): OK"
        return 0
    else
        echo "  PING $name ($ip): FAILED"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# SEMS API check
# ---------------------------------------------------------------------------

sems_login() {
    local response login_payload
    login_payload=$(jq -nc --arg a "$SEMS_ACCOUNT" --arg p "$SEMS_PASSWORD" \
        '{account: $a, pwd: $p}')
    response=$(curl -s -X POST \
        "https://www.semsportal.com/api/v2/Common/CrossLogin" \
        -H "Content-Type: application/json" \
        -H 'Token: {"version":"","client":"ios","language":"en"}' \
        -d "$login_payload")

    local code
    code=$(echo "$response" | jq -r '.code // empty')
    if [ "$code" != "0" ]; then
        echo "  SEMS login failed (code=$code)" >&2
        return 1
    fi

    # Return the full token data (includes api base URL).
    echo "$response" | jq -c '{
        uid: .data.uid,
        timestamp: .data.timestamp,
        token: .data.token,
        client: "ios",
        version: "",
        language: "en",
        api: .api
    }'
}

check_sems() {
    if [ -z "$SEMS_ACCOUNT" ] || [ -z "$SEMS_PASSWORD" ]; then
        echo "  SEMS: skipped (no credentials configured)"
        return 0
    fi

    # Use Python for the SEMS API calls — jq + bash struggle with the
    # password's special characters, and the API returns inconsistent
    # data shapes (string vs array for station IDs).
    local result
    result=$(python3 -c "
import json, sys, urllib.request

def api_post(url, token, data=None):
    req = urllib.request.Request(
        url,
        data=json.dumps(data or {}).encode(),
        headers={
            'Content-Type': 'application/json',
            'token': json.dumps(token) if isinstance(token, dict) else token,
        },
    )
    return json.loads(urllib.request.urlopen(req, timeout=30).read())

# Login
login_token = '{\"version\":\"\",\"client\":\"ios\",\"language\":\"en\"}'
creds = {'account': '''$SEMS_ACCOUNT''', 'pwd': '''$SEMS_PASSWORD'''}
login = api_post('https://www.semsportal.com/api/v2/Common/CrossLogin', login_token, creds)

if login.get('code') not in (0, '0'):
    print('LOGIN_FAILED')
    sys.exit(0)

token = {
    'uid': login['data']['uid'],
    'timestamp': login['data']['timestamp'],
    'token': login['data']['token'],
    'client': 'ios',
    'version': '',
    'language': 'en',
}
api = login['api']

# Get station ID (API returns a single string, not an array)
stations = api_post(api + 'PowerStation/GetPowerStationIdByOwner', token)
station_id = stations.get('data', '')
if not station_id:
    print('NO_STATIONS')
    sys.exit(0)

# If it's a list, take the first; if string, use directly.
if isinstance(station_id, list):
    station_id = station_id[0].get('id', station_id[0].get('powerstation_id', ''))

# Get inverter details
detail = api_post(api + 'v3/PowerStation/GetMonitorDetailByPowerstationId', token, {'powerStationId': station_id})
station_name = detail.get('data', {}).get('info', {}).get('stationname', 'Unknown')
inverters = detail.get('data', {}).get('inverter', [])

for inv in inverters:
    sn = inv.get('sn', 'unknown')
    status = inv.get('status', -1)
    name = inv.get('name', sn)
    power = inv.get('out_pac', 0)
    # Output: name|sn|status|power|station_name
    print(f'{name}|{sn}|{status}|{power}|{station_name}')
" 2>&1) || true

    if [ "$result" = "LOGIN_FAILED" ]; then
        echo "  SEMS: login failed"
        return 1
    fi

    if [ "$result" = "NO_STATIONS" ]; then
        echo "  SEMS: no power stations found"
        return 1
    fi

    if [ -z "$result" ]; then
        echo "  SEMS: API error (empty response)"
        return 1
    fi

    local all_ok=true

    while IFS='|' read -r inv_name inv_sn inv_status inv_power station_name; do
        # Status: 1 = normal/generating, 0 = waiting, -1 = offline/fault
        if [ "$inv_status" = "1" ] || [ "$inv_status" = "0" ]; then
            echo "  SEMS $inv_name ($inv_sn): status=$inv_status, ${inv_power}W (ok)"
        else
            echo "  SEMS $inv_name ($inv_sn): status=$inv_status (OFFLINE/FAULT)"
            all_ok=false

            local state_key="sems_${inv_sn}"
            if [ "$(get_state "$state_key")" != "alert" ]; then
                notify "Inverter Offline (SEMS)" \
                    "$inv_name ($inv_sn) at $station_name is reporting status $inv_status via SEMS cloud."
                set_state "$state_key" "alert"
            fi
        fi
    done <<< "$result"

    if $all_ok; then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    init_state

    echo "$(date '+%Y-%m-%d %H:%M:%S') — solarmon check"

    local any_failure=false

    # --- Ping checks ---
    for i in $(seq 0 $((INVERTER_COUNT - 1))); do
        local name ip
        name=$(jq -r ".inverters[$i].name" "$CONFIG")
        ip=$(jq -r ".inverters[$i].ip // empty" "$CONFIG")

        if ! check_ping "$name" "$ip"; then
            any_failure=true

            local state_key="ping_${name}"
            if [ "$(get_state "$state_key")" != "alert" ]; then
                notify "Inverter Unreachable" \
                    "$name ($ip) is not responding to ping. It may have lost its Wi-Fi connection."
                set_state "$state_key" "alert"
            fi
        else
            local state_key="ping_${name}"
            if [ "$(get_state "$state_key")" = "alert" ]; then
                notify "Inverter Back Online" \
                    "$name ($ip) is responding again." \
                    "0"
                set_state "$state_key" "ok"
            fi
        fi
    done

    # --- SEMS API check ---
    check_sems || any_failure=true

    # --- Clear SEMS alerts for inverters that recovered ---
    if [ -n "$SEMS_ACCOUNT" ] && [ -n "$SEMS_PASSWORD" ]; then
        # If SEMS check passed entirely, clear any lingering SEMS alerts.
        if ! $any_failure; then
            for key in $(jq -r 'to_entries[] | select(.key | startswith("sems_")) | select(.value == "alert") | .key' "$STATE_FILE" 2>/dev/null); do
                notify "Inverter Recovered (SEMS)" \
                    "$(echo "$key" | sed 's/^sems_//') is back online in SEMS." \
                    "0"
                set_state "$key" "ok"
            done
        fi
    fi

    # --- Daily heartbeat (8:xx AM slot) ---
    local hour
    hour=$(date '+%H')
    if [ "$hour" = "08" ]; then
        local last_heartbeat
        last_heartbeat=$(get_state "last_heartbeat")
        local today
        today=$(date '+%Y-%m-%d')
        if [ "$last_heartbeat" != "$today" ]; then
            notify "Solarmon Running" \
                "Daily check-in: monitoring is active. Last result: $(if $any_failure; then echo "issues detected"; else echo "all OK"; fi)." \
                "-1"
            set_state "last_heartbeat" "$today"
        fi
    fi

    if $any_failure; then
        echo "  Result: ISSUES DETECTED"
        exit 1
    else
        echo "  Result: All OK"
        exit 0
    fi
}

main "$@"
