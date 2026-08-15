#!/bin/bash
set -uo pipefail

ENV_KISMET_SET=0
ENV_API_KEY_SET=0
ENV_WIFI_IFACE_SET=0
ENV_API_KEY_FILE_SET=0

if [[ -n "${KISMET+x}" ]]; then
    ENV_KISMET_SET=1
    ENV_KISMET_VALUE="$KISMET"
fi

if [[ -n "${API_KEY+x}" ]]; then
    ENV_API_KEY_SET=1
    ENV_API_KEY_VALUE="$API_KEY"
fi

if [[ -n "${WIFI_IFACE+x}" ]]; then
    ENV_WIFI_IFACE_SET=1
    ENV_WIFI_IFACE_VALUE="$WIFI_IFACE"
fi

if [[ -n "${API_KEY_FILE+x}" ]]; then
    ENV_API_KEY_FILE_SET=1
    ENV_API_KEY_FILE_VALUE="$API_KEY_FILE"
fi

DEFAULT_KISMET_URL="http://127.0.0.1:2501"
DEFAULT_CONFIG_FILE="$HOME/.config/daggmask/config"

KISMET="$DEFAULT_KISMET_URL"
API_KEY=""
WIFI_IFACE=""
API_KEY_FILE=""
CONFIG_FILE="${DAGGMASK_CONFIG:-$DEFAULT_CONFIG_FILE}"
INTERRUPTED=0
SAMPLE_DATA=0

die()
{
    local msg="$1"
    local hint="${2:-}"

    printf '\033[1;31m[ERROR]\033[0m %s\n' "$msg" >&2

    if [ -n "$hint" ]; then
        printf '\033[90m  Hint:\033[0m %s\n' "$hint" >&2
    fi

    exit 1
}

warn()
{
    printf '\033[1;33m[WARN]\033[0m %s\n' "$1" >&2
}

info()
{
    printf '\033[1;36m[INFO]\033[0m %s\n' "$1" >&2
}

print_usage()
{
    cat <<'EOF'
Usage: daggmask.sh [options]

Options:
  --kismet-url <url>        Kismet base URL (default: http://127.0.0.1:2501)
  --api-key <key>           Kismet API session key
  --api-key-file <path>     Read API key from file (first line)
  --wifi-iface <iface>      Wireless interface (monitor mode preferred)
  --sample-data             Render built-in sample data (no Kismet required)
  --config <path>           Config file path (default: ~/.config/daggmask/config)
  -h, --help                Show this help text

Config file keys:
  KISMET_URL=...
  API_KEY=...
  API_KEY_FILE=...
  WIFI_IFACE=...
EOF
}

trim_value()
{
    local v="${1:-}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

set_config_key()
{
    local key="$1"
    local value="$2"

    case "$key" in
        KISMET_URL|KISMET)
            KISMET="$value"
            ;;
        API_KEY)
            API_KEY="$value"
            ;;
        API_KEY_FILE)
            API_KEY_FILE="$value"
            ;;
        WIFI_IFACE)
            WIFI_IFACE="$value"
            ;;
    esac
}

load_config_file()
{
    local cfg="$1"
    local raw
    local line
    local key
    local value

    [ ! -f "$cfg" ] && return
    [ ! -r "$cfg" ] && die "Config file is not readable: $cfg" "Check file permissions and ownership."

    while IFS= read -r raw || [ -n "$raw" ]; do
        line="${raw%%#*}"
        line=$(trim_value "$line")
        [ -z "$line" ] && continue
        [[ "$line" != *=* ]] && continue

        key="${line%%=*}"
        value="${line#*=}"
        key=$(trim_value "$key")
        value=$(trim_value "$value")

        if [[ ( "$value" == \"*\" && "$value" == *\" ) || ( "$value" == \'*\' && "$value" == *\' ) ]]; then
            value="${value:1:${#value}-2}"
        fi

        set_config_key "$key" "$value"
    done < "$cfg"
}

ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
    case "${ARGS[$i]}" in
        --config)
            (( i + 1 < ${#ARGS[@]} )) || die "--config requires a value" "Example: --config ~/.config/daggmask/config"
            CONFIG_FILE="${ARGS[$((i + 1))]}"
            ;;
    esac
done

load_config_file "$CONFIG_FILE"

if (( ENV_KISMET_SET == 1 )); then
    KISMET="$ENV_KISMET_VALUE"
fi

if (( ENV_API_KEY_SET == 1 )); then
    API_KEY="$ENV_API_KEY_VALUE"
fi

if (( ENV_WIFI_IFACE_SET == 1 )); then
    WIFI_IFACE="$ENV_WIFI_IFACE_VALUE"
fi

if (( ENV_API_KEY_FILE_SET == 1 )); then
    API_KEY_FILE="$ENV_API_KEY_FILE_VALUE"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kismet-url)
            [[ $# -ge 2 ]] || die "--kismet-url requires a value" "Example: --kismet-url http://127.0.0.1:2501"
            KISMET="$2"
            shift 2
            ;;
        --api-key)
            [[ $# -ge 2 ]] || die "--api-key requires a value" "Use --api-key-file for safer key handling."
            API_KEY="$2"
            shift 2
            ;;
        --api-key-file)
            [[ $# -ge 2 ]] || die "--api-key-file requires a value" "Example: --api-key-file ~/.config/daggmask/kismet.key"
            API_KEY_FILE="$2"
            shift 2
            ;;
        --wifi-iface)
            [[ $# -ge 2 ]] || die "--wifi-iface requires a value" "Example: --wifi-iface wlan1mon"
            WIFI_IFACE="$2"
            shift 2
            ;;
        --sample-data)
            SAMPLE_DATA=1
            shift
            ;;
        --config)
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1" "Run with --help to see supported options."
            ;;
    esac
done

TMPDIR=$(mktemp -d)
cleanup() {
    rm -rf "$TMPDIR"
}

on_interrupt() {
    INTERRUPTED=1
}

trap cleanup EXIT
trap on_interrupt INT TERM

# =============================================================
# Colors
# =============================================================

RESET='\033[0m'
BOLD='\033[1m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
WHITE='\033[37m'
GRAY='\033[90m'

# =============================================================
# Column widths
# =============================================================

BSSID_W=17
ESSID_W=24
PWR_W=4
CH_W=3
CLIENTS_W=8
ENC_W=5
HS_W=4
MFR_W=16
PKTS_W=8
DATA_W=8
AGE_W=8
AP_W=19

# =============================================================
# Helpers
# =============================================================

HIDDEN_SSID='[HIIDEN]'

strip_ansi()
{
    printf '%s' "$1" | perl -pe 's/\e\[[0-9;]*[A-Za-z]//g'
}

normalize_ssid()
{
    local value="${1:-}"

    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ -z "$value" || "$value" == "<hidden>" || "$value" == "null" || "$value" =~ ^[[:space:]]*$ || "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$HIDDEN_SSID"
        return
    fi

    printf '%s' "${value:0:32}"
}

format_essid()
{
    local value
    local max_width="${1:-24}"

    value=$(normalize_ssid "${2:-}")

    if (( ${#value} <= max_width )); then
        printf '%s' "$value"
        return
    fi

    if (( max_width <= 3 )); then
        printf '%s' "${value:0:max_width}"
        return
    fi

    printf '%s...' "${value:0:max_width-3}"
}

resolve_manufacturer()
{
    local manuf="${1:-}"
    local bssid="${2:-?}"

    manuf="${manuf//$'\r'/}"
    manuf="${manuf//$'\n'/}"
    manuf="${manuf#"${manuf%%[![:space:]]*}"}"
    manuf="${manuf%"${manuf##*[![:space:]]}"}"

    if [[ -z "$manuf" || "$manuf" == "null" || "$manuf" == "?" || "$manuf" =~ ^[0-9]+$ ]]; then
        printf '%s' "$bssid"
        return
    fi

    printf '%s' "$manuf"
}

format_manufacturer()
{
    local value
    local max_width="${1:-16}"

    value=$(resolve_manufacturer "${2:-}" "${3:-?}")

    if (( ${#value} <= max_width )); then
        printf '%s' "$value"
        return
    fi

    if (( max_width <= 3 )); then
        printf '%s' "${value:0:max_width}"
        return
    fi

    printf '%s...' "${value:0:max_width-3}"
}

pad_text()
{
    local text="${1:-}"
    local width="${2:-0}"
    local align="${3:-left}"
    local visible
    local pad

    visible=$(strip_ansi "$text")
    pad=$(( width - ${#visible} ))

    if (( pad < 0 )); then
        printf '%s' "$text"
        return
    fi

    if [[ "$align" == "right" ]]; then
        printf '%*s%s' "$pad" "" "$text"
    else
        printf '%s%*s' "$text" "$pad" ""
    fi
}

human_bytes()
{
    local bytes="$1"

    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "?"
        return
    fi

    if [ "$bytes" -ge 1073741824 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1fG", b/1073741824}'
    elif [ "$bytes" -ge 1048576 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1fM", b/1048576}'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1fK", b/1024}'
    else
        echo "$bytes"
    fi
}

color_signal()
{
    local pwr="$1"

    if ! [[ "$pwr" =~ ^-?[0-9]+$ ]]; then
        printf '%s' "$pwr"
        return
    fi

    if [ "$pwr" -ge -50 ]; then
        printf '%b%s%b' "$GREEN" "$pwr" "$RESET"
    elif [ "$pwr" -ge -65 ]; then
        printf '%b%s%b' "$YELLOW" "$pwr" "$RESET"
    else
        printf '%b%s%b' "$RED" "$pwr" "$RESET"
    fi
}

color_enc()
{
    case "$1" in
        WPA3)
            printf '%bWPA3%b' "$GREEN" "$RESET"
            ;;
        WPA2)
            printf '%bWPA2%b' "$CYAN" "$RESET"
            ;;
        WPA)
            printf '%bWPA%b' "$YELLOW" "$RESET"
            ;;
        OPN)
            printf '%bOPN%b' "$RED" "$RESET"
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

color_hs()
{
    if [ "$1" = "YES" ]; then
        printf '%bYES%b' "$GREEN" "$RESET"
    else
        printf '%bNO%b' "$GRAY" "$RESET"
    fi
}

require_cmd()
{
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1" "Install it and retry."
}

valid_kismet_url()
{
    [[ "$KISMET" =~ ^https?://[^[:space:]]+$ ]]
}

detect_monitor_iface()
{
    iw dev 2>/dev/null | awk '
        $1 == "Interface" {iface = $2}
        $1 == "type" && $2 == "monitor" {print iface; exit}
    '
}

list_ifaces()
{
    iw dev 2>/dev/null | awk '$1 == "Interface" {print $2}' | paste -sd ', ' -
}

load_api_key_file()
{
    [ -z "$API_KEY_FILE" ] && return
    [ -f "$API_KEY_FILE" ] || die "API key file not found: $API_KEY_FILE" "Create the file or use --api-key."
    [ -r "$API_KEY_FILE" ] || die "API key file is not readable: $API_KEY_FILE" "Adjust permissions (for example: chmod 600)."

    API_KEY=$(head -n 1 "$API_KEY_FILE")
    API_KEY=$(trim_value "$API_KEY")
}

preflight_api_check()
{
    local response_file="$TMPDIR/kismet_preflight.json"
    local response_preview
    local http_code

    http_code=$(curl -s --max-time 4 \
        --cookie "KISMET=$API_KEY" \
        -X POST \
        -d 'json={"start":0,"length":1}' \
        -o "$response_file" \
        -w '%{http_code}' \
        "$KISMET/devices/views/phydot11_accesspoints/devices.json" 2>/dev/null) || {
        die "Failed to connect to Kismet URL ($KISMET)." "Verify host/port, Kismet service status, and network reachability."
    }

    if [[ "$http_code" != "200" ]]; then
        response_preview=$(tr '\n' ' ' < "$response_file" | head -c 220)

        case "$http_code" in
            401|403)
                die "Kismet authentication failed (HTTP $http_code)." "Verify API key and Kismet API permissions. Response: ${response_preview:-<empty>}"
                ;;
            404)
                die "Kismet endpoint not found (HTTP 404)." "Verify KISMET URL and API base path. Response: ${response_preview:-<empty>}"
                ;;
            5??)
                die "Kismet server error (HTTP $http_code)." "Check Kismet service health/logs. Response: ${response_preview:-<empty>}"
                ;;
            *)
                die "Unexpected Kismet HTTP status ($http_code)." "Response: ${response_preview:-<empty>}"
                ;;
        esac
    fi

    if ! jq empty "$response_file" >/dev/null 2>&1; then
        response_preview=$(tr '\n' ' ' < "$response_file" | head -c 220)
        die "Kismet API returned non-JSON payload with HTTP 200." "URL: $KISMET | Response: ${response_preview:-<empty>}"
    fi
}

preflight()
{
    if (( SAMPLE_DATA == 1 )); then
        require_cmd awk
        require_cmd perl
        require_cmd sort
        info "Sample data mode enabled (Kismet/API checks skipped)"
        return
    fi

    require_cmd curl
    require_cmd jq
    require_cmd iw
    require_cmd awk
    require_cmd perl
    require_cmd sort

    valid_kismet_url || die "Invalid Kismet URL: $KISMET" "Expected format: http://host:port"

    load_api_key_file

    if [ -z "$WIFI_IFACE" ]; then
        WIFI_IFACE=$(detect_monitor_iface)
    fi

    if [ -z "$WIFI_IFACE" ]; then
        local available
        available=$(list_ifaces)
        die "No monitor interface configured." "Set --wifi-iface or WIFI_IFACE. Available interfaces: ${available:-none found}."
    fi

    if ! iw dev "$WIFI_IFACE" info >/dev/null 2>&1; then
        die "Interface '$WIFI_IFACE' was not found." "Set a valid interface with --wifi-iface."
    fi

    if [ -z "$API_KEY" ]; then
        warn "API key is empty. This only works if your Kismet allows unauthenticated local API access."
    fi

    info "Running preflight checks against $KISMET"
    preflight_api_check
    info "Preflight passed. Using Kismet $KISMET on interface $WIFI_IFACE"
}

write_sample_apinfo()
{
    local now_ts="$1"

    cat > "$TMPDIR/apinfo.tsv" <<EOF
atlas-lab	A2:14:7C:90:3B:11	Nimbus Wireless Systems	-47	40	2	WPA2	NO	1203	9472	$((now_ts-660))
atlas-lab	A2:14:7C:90:3B:12	Nimbus Wireless Systems	-60	40	21	WPA2	YES	18942	540	$((now_ts-2))
meridian-core	B6:29:51:8D:44:20	Northbridge Telecom	-60	1	1	WPA2	NO	18420	0	$((now_ts-2))
city-guest-zone	C8:33:9F:22:5A:70	Coastal Network Devices Co	-68	6	33	WPA3	NO	501823	194857600	$((now_ts-34))
city-guest-zone	C8:33:9F:22:5A:71		-71	6	8	WPA3	NO	12812	4096	$((now_ts-95))
[HIIDEN]	DE:48:AA:10:6F:99	Unknown Vendor	-79	11	0	WPA2	NO	208	0	$((now_ts-15))
EOF
}

# =============================================================
# Main loop
# =============================================================

preflight

while (( INTERRUPTED == 0 )); do
    if (( SAMPLE_DATA == 1 )); then
        NOW=$(date +%s)
        CHANNEL="SMP"
        write_sample_apinfo "$NOW"
    else
        # =========================================================
        # Fetch AP list
        # =========================================================

        curl -s --max-time 2 \
            --cookie "KISMET=$API_KEY" \
            -X POST \
            -d 'json={"start":0,"length":1000}' \
            "$KISMET/devices/views/phydot11_accesspoints/devices.json" \
            > "$TMPDIR/aps.json" &

        AP_PID=$!

        # Current capture channel
        CHANNEL=$(iw dev "$WIFI_IFACE" info 2>/dev/null |
            awk '$1 == "channel" {print $2; exit}')

        wait "$AP_PID"

        if (( INTERRUPTED == 1 )); then
            break
        fi

        # =========================================================
        # Validate JSON
        # =========================================================

        if ! jq empty "$TMPDIR/aps.json" 2>/dev/null; then
            sleep 1
            continue
        fi

        # =========================================================
        # Get device keys
        # =========================================================

        jq -r '
            .[]
            | [
                .["kismet.device.base.key"],
                .["kismet.device.base.macaddr"]
            ]
            | @tsv
        ' "$TMPDIR/aps.json" > "$TMPDIR/keys.tsv"

        # =========================================================
        # Fetch FULL device records
        # =========================================================

        rm -f "$TMPDIR/device_"*

        while IFS=$'\t' read -r key bssid; do
            [ -z "$key" ] && continue

            SAFE_KEY=$(echo "$key" | tr '/:' '__')

            (
                curl -s --max-time 2 \
                    --cookie "KISMET=$API_KEY" \
                    "$KISMET/devices/by-key/$key/device.json" \
                    > "$TMPDIR/device_$SAFE_KEY.json"
            ) &
        done < "$TMPDIR/keys.tsv"

        wait

        # =========================================================
        # Parse AP data
        # =========================================================

        : > "$TMPDIR/apinfo.tsv"

        while IFS=$'\t' read -r key bssid; do
            [ -z "$key" ] && continue

            SAFE_KEY=$(echo "$key" | tr '/:' '__')
            FILE="$TMPDIR/device_$SAFE_KEY.json"

            [ ! -s "$FILE" ] && continue

            jq -r '

            # -------------------------------------------------
            # Basic information
            # -------------------------------------------------

            (.["kismet.device.base.macaddr"] // "?") as $bssid |

            (
                .["kismet.device.base.signal"]?
                ["kismet.common.signal.last_signal"]
                // "?"
            ) as $pwr |

            (. ["kismet.device.base.channel"] // "?") as $ch |

            (. ["kismet.device.base.manuf"] // "") as $mfr |

            (.["kismet.device.base.packets.total"] // 0) as $packets |

            (.["kismet.device.base.datasize"] // 0) as $datasize |

            (.["kismet.device.base.last_time"] // 0) as $last |

            # -------------------------------------------------
            # Client count
            # -------------------------------------------------

            (
                .["dot11.device"]?
                ["dot11.device.num_associated_clients"]
                // 0
            ) as $clients |

            # -------------------------------------------------
            # ESSID
            # -------------------------------------------------

            (
                [
                    .["dot11.device"]?
                    ["dot11.device.last_beaconed_ssid_record"]?
                    ["dot11.advertisedssid.ssid"],

                    (
                        .["dot11.device"]?
                        ["dot11.device.advertised_ssid_map"]?
                        // {}
                        | to_entries[]
                        | .value["dot11.advertisedssid.ssid"]?
                    ),

                    (
                        .["dot11.device"]?
                        ["dot11.device.responded_ssid_map"]?
                        // {}
                        | to_entries[]
                        | .value["dot11.advertisedssid.ssid"]?
                    )
                ]
                | map(select(type == "string"))
                | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
                | map(select(length > 0))
                | .[0] // "[HIIDEN]"
            ) as $ssid |

            # -------------------------------------------------
            # Encryption
            # -------------------------------------------------

            (
                .["kismet.device.base.crypt"] // ""
            ) as $crypt |

            (
                if ($crypt | test("WPA3"; "i")) then
                    "WPA3"
                elif ($crypt | test("WPA2"; "i")) then
                    "WPA2"
                elif ($crypt | test("WPA"; "i")) then
                    "WPA"
                else
                    "OPN"
                end
            ) as $enc |

            # -------------------------------------------------
            # Handshake
            #
            # Kismet stores this as:
            #
            # dot11.device.wpa_handshake_list
            #
            # It is an object keyed by client MAC.
            #
            # Any key means a handshake has been captured.
            # -------------------------------------------------

            (
                .["dot11.device"]?
                ["dot11.device.wpa_handshake_list"]
                // {}
            ) as $handshakes |

            (
                if (($handshakes | length) > 0) then
                    "YES"
                else
                    "NO"
                end
            ) as $hs |

            # -------------------------------------------------
            # Output
            # -------------------------------------------------

            [
                $ssid,
                $bssid,
                $mfr,
                $pwr,
                $ch,
                $clients,
                $enc,
                $hs,
                $packets,
                $datasize,
                $last
            ]

            | @tsv

            ' "$FILE" >> "$TMPDIR/apinfo.tsv"
        done < "$TMPDIR/keys.tsv"

        # =========================================================
        # Current time
        # =========================================================

        NOW=$(date +%s)
    fi


    # =========================================================
    # Build screen
    # =========================================================

    {
        printf '%bDAGGMASK%b | CH %-3s| AP %-3s| HS %-3s| UPD %s\n' \
            "$BOLD$CYAN" "$RESET" \
            "${CHANNEL:-?}" \
            "$(wc -l < "$TMPDIR/apinfo.tsv")" \
            "$(awk -F'\t' '$8 == "YES" {n++} END {print n+0}' "$TMPDIR/apinfo.tsv")" \
            "$(date '+%H:%M:%S')"

        printf '\n'

        printf '%s %s %s %s %s %s %s %s %s %s\n' \
            "$(pad_text "AP/BSSID" "$AP_W" left)" \
            "$(pad_text "MFR" "$MFR_W" left)" \
            "$(pad_text "PWR" "$PWR_W" right)" \
            "$(pad_text "CH" "$CH_W" right)" \
            "$(pad_text "CLIENTS" "$CLIENTS_W" right)" \
            "$(pad_text "ENC" "$ENC_W" left)" \
            "$(pad_text "HS" "$HS_W" left)" \
            "$(pad_text "PKTS" "$PKTS_W" right)" \
            "$(pad_text "DATA" "$DATA_W" right)" \
            "$(pad_text "AGE" "$AGE_W" right)"

        printf '\n'

        sort -t $'\t' -k1,1 -k2,2 "$TMPDIR/apinfo.tsv" > "$TMPDIR/apinfo_sorted.tsv"

        current_ssid=""
        mapfile -t ap_rows < "$TMPDIR/apinfo_sorted.tsv"

        for i in "${!ap_rows[@]}"; do
            if (( INTERRUPTED == 1 )); then
                break
            fi

            IFS=$'\t' read -r ssid bssid mfr pwr ch clients enc hs packets datasize last <<< "${ap_rows[$i]}"
            [ -z "$bssid" ] && continue

            ssid_display=$(format_essid "$ESSID_W" "$ssid")

            if [[ -z "$ssid_display" ]]; then
                ssid_display="$HIDDEN_SSID"
            fi

            if [[ "$ssid_display" != "$current_ssid" ]]; then
                if [[ -n "$current_ssid" ]]; then
                    printf '\n'
                fi

                current_ssid="$ssid_display"
                printf '%b%s%b\n' "$BOLD$WHITE" "$current_ssid" "$RESET"
            fi

            next_ssid_display=""
            if (( i + 1 < ${#ap_rows[@]} )); then
                IFS=$'\t' read -r next_ssid _ <<< "${ap_rows[$((i + 1))]}"
                next_ssid_display=$(format_essid "$ESSID_W" "$next_ssid")
            fi

            if [[ "$ssid_display" == "$next_ssid_display" ]]; then
                branch_prefix="├─"
            else
                branch_prefix="╰─"
            fi

            if [[ "$packets" =~ ^[0-9]+$ ]]; then
                if [ "$packets" -ge 1000000 ]; then
                    packets_display=$(awk -v n="$packets" 'BEGIN {printf "%.1fM", n/1000000}')
                elif [ "$packets" -ge 1000 ]; then
                    packets_display=$(awk -v n="$packets" 'BEGIN {printf "%.1fK", n/1000}')
                else
                    packets_display="$packets"
                fi
            else
                packets_display="?"
            fi

            data_display=$(human_bytes "$datasize")

            if [[ "$last" =~ ^[0-9]+$ ]] && [ "$last" -gt 0 ]; then
                AGE=$((NOW - last))

                if [ "$AGE" -lt 60 ]; then
                    age_display="${AGE}s"
                elif [ "$AGE" -lt 3600 ]; then
                    age_display="$((AGE / 60))m"
                elif [ "$AGE" -lt 86400 ]; then
                    age_display="$((AGE / 3600))h"
                else
                    age_display="$((AGE / 86400))d"
                fi
            else
                age_display="?"
            fi

            ap_display="$branch_prefix $bssid"
            mfr_display=$(format_manufacturer "$MFR_W" "$mfr" "$bssid")

            printf '%s %s %s %s %s %s %s %s %s %s\n' \
                "$(pad_text "$ap_display" "$AP_W" left)" \
                "$(pad_text "$mfr_display" "$MFR_W" left)" \
                "$(pad_text "$(color_signal "$pwr")" "$PWR_W" right)" \
                "$(pad_text "$ch" "$CH_W" right)" \
                "$(pad_text "$clients" "$CLIENTS_W" right)" \
                "$(pad_text "$(color_enc "$enc")" "$ENC_W" left)" \
                "$(pad_text "$(color_hs "$hs")" "$HS_W" left)" \
                "$(pad_text "$packets_display" "$PKTS_W" right)" \
                "$(pad_text "$data_display" "$DATA_W" right)" \
                "$(pad_text "$age_display" "$AGE_W" right)"
        done

        printf '\n'
        printf '%bPress Ctrl+C to quit.%b\n' "$GRAY" "$RESET"
    } > "$TMPDIR/screen.txt"


    # =========================================================
    # Display
    # =========================================================

    printf '\033[2J\033[H'

    cat "$TMPDIR/screen.txt"

    sleep 1

done

printf '\nExiting DAGGMASK.\n'