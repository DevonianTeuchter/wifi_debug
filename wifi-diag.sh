#!/usr/bin/env bash
# wifi_diag.sh
# Monitor Wifi and VPN health in the vain hope of trying to track
# intermittent failures...

set -euo pipefail

# Config (defaults; overridden via CLI flags)
VPN_TARGET=""               # IP address inside VPN to test "pingability"
WIFI_IFACE=""               # wifi interface (eg. wlp2s0)
VPN_IFACE=""                # VPN interface (eg. tun0)
INTERVAL_SEC=5              # Sampling interval
SINCE_WINDOW="5 min ago"    # Log lines leading to issue
LOG_DIR="${PWD}"            # Logging directory
LOGFILE=""                  # Log file
VPN_FQDN=""                 # VPN-only FQDN to test (eg. ibm.com)
VPN_DNS_SERVER=""           # VPN DNS server
PUBLIC_FQDN="example.com"   # Public domain to sanity-check DNS path
PUBLIC_DNS_SERVER="8.8.8.8" # Public DNS server (google!)
DNS_TIMEOUT=2               # dig timeout (seconds)
ROUTE_HASH_INITIAL=""       # Initial routing table hash for change detection


usage() {
  cat <<EOF
Usage: sudo ./wifi_diag.sh -t <VPN_INTERNAL_IP> [options]

Required:
  -t, --target <IP>        VPN-only IP (eg. 10.x.x.x)

Optional:
  -w, --wifi <if>          wifi interface (eg. wlp2s0). [Auto-detected if omitted]
  -v, --vpn <if>           VPN interface (eg. tun0/tap0). [Auto-detected if omitted]
  -i, --interval <sec>     Sampling interval (default: ${INTERVAL_SEC})
  -s, --since <window>     Journald window for diagnostics on failure (default: "${SINCE_WINDOW}")
  -o, --outdir <dir>       Directory to write logs (default: pwd)
  -f, --fqdn <name>        VPN-only FQDN to test resolution (eg. intranet.corp.local)
  -d, --dns <server>       VPN DNS server (eg., 10.20.30.40)
  -p, --public <name>      Public FQDN to test (default: ${PUBLIC_FQDN})
      --public-dns <server>  Public DNS server (default: ${PUBLIC_DNS_SERVER})
      --dns-timeout <sec>  dig timeout per query (default: ${DNS_TIMEOUT})

Examples:
  sudo ./wifi_diag.sh -t 10.20.30.40
  sudo ./wifi_diag.sh -t 10.20.30.40 -w wlp3s0 -v tun0 -i 3
  sudo ./wifi_diag.sh -t 10.20.30.40 -f ibm.com -d 10.20.30.40
EOF
}

# Utils
command_exists() { command -v "$1" >/dev/null 2>&1; }

log() {
  local msg="$1"
  echo "[$(date -Iseconds)] $msg" | tee -a "$LOGFILE"
}

# Auto-detect wifi interface (prefer nmcli, fallback to iw)
detect_wifi_iface() {
  if [[ -n "${WIFI_IFACE}" ]]; then
    log "Using provided wifi interface: ${WIFI_IFACE}"
    return
  fi
  if command_exists nmcli; then
    WIFI_IFACE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')"
  fi
  if [[ -z "${WIFI_IFACE}" ]] && command_exists iw; then
    WIFI_IFACE="$(iw dev | awk '/Interface/{print $2; exit}')"
  fi
  if [[ -z "${WIFI_IFACE}" ]]; then
    log "ERROR: Could not auto-detect wifi interface. Use -w/--wifi to specify"
    exit 1
  fi
  log "Auto-detected wifi interface: ${WIFI_IFACE}"
}

# Auto-detect VPN interface (via route to target or first tun/tap)
detect_vpn_iface() {
  if [[ -n "${VPN_IFACE}" ]]; then
    log "Using VPN interface: ${VPN_IFACE}"
    return
  fi
  # Try to detect from route to VPN target
  if command_exists ip; then
    VPN_IFACE="$(ip -4 route get "${VPN_TARGET}" 2>/dev/null | awk '
      { for(i=1;i<=NF;i++){
          if($i=="dev"){
            print $(i+1);
            exit
          }
        }
      }
    ')"
    [[ -n "${VPN_IFACE}" ]] && log "Detected interface '${VPN_IFACE}'"
  fi
  # If detection fails or detects wifi/wired/etc, pick first tun/tap - who has
  # more than one VPN ;-)
  if [[ -z "${VPN_IFACE}" || "${VPN_IFACE}" == "${WIFI_IFACE}" ]]; then
    VPN_IFACE="$(ip -o link show | awk -F': ' '
      /\btun[0-9]*\b|\btap[0-9]*\b/{ print $2; exit }
    ')"
  fi
  if [[ -z "${VPN_IFACE}" ]]; then
    log "WARNING: Could not auto-detect VPN interface. Will ping target without it!"
  else
    log "Auto-detected VPN interface: ${VPN_IFACE}"
  fi
}

# Get default gateway for wifi
wifi_gateway() {
  ip route | awk -v IFACE="${WIFI_IFACE}" '
    $1=="default" && $0 ~ (" dev " IFACE " ") { print $3; exit }
  '
}

do_ping() {
  local dest="$1"; local iface_opt="$2"; local timeout="${3:-1}"
  if [[ -n "${iface_opt}" ]]; then
    ping -c1 -W "${timeout}" -I "${iface_opt}" "${dest}" >/dev/null 2>&1
  else
    ping -c1 -W "${timeout}" "${dest}" >/dev/null 2>&1
  fi
  return $?
}

dump_diagnostics() {
  # dump various command outputs in the hope that something is useful...
  local since_when
  since_when="$(date -Iseconds -d "${SINCE_WINDOW}")"
  log "BEGIN SNAPSHOT (since ${since_when})"
  {
    echo "Basic network stats:"
    if command_exists ip; then
      echo "# Interfaces (ip link):"
      ip -br link

      echo
      echo "# IPv4 addresses (ip -4 addr):"
      ip -4 addr

      echo
      echo "# Current routing table (ip route):"
      ip route

      if [[ -n "${VPN_IFACE}" ]]; then
        echo
        echo "# VPN interface addresses (ip -4 addr show ${VPN_IFACE}):"
        ip -4 addr show "${VPN_IFACE}" || echo "'ip addr show' not available"
      fi

      echo
      echo "# Route to VPN target (ip route get ${VPN_TARGET}):"
      ip -4 route get "${VPN_TARGET}" || echo "'ip route get' not available"
    fi

     if command_exists iw; then
      echo
      echo "# wifi link (iw dev ${WIFI_IFACE} link):"
      iw dev "${WIFI_IFACE}" link || echo "'iw link' not available"

      echo
      echo "# iw dev ${WIFI_IFACE} link:"
      iw dev "${WIFI_IFACE}" link || echo "iw link failed"

      echo
      echo "# iw dev ${WIFI_IFACE} station dump:"
      iw dev "${WIFI_IFACE}" station dump || echo "iw station dump failed (not associated?)"

      echo
      echo "# iw dev ${WIFI_IFACE} info (channel/width):"
      iw dev "${WIFI_IFACE}" info || echo "iw info failed"
    fi

    if command_exists nmcli; then
      echo
      echo "# nmcli device status:"
      nmcli -t -f DEVICE,STATE,CONNECTION,TYPE device status || echo "'nmcli device status' not available"

      echo
      echo "# nmcli device show ${WIFI_IFACE}:"
      nmcli device show "${WIFI_IFACE}" || echo "'nmcli device show' not available"

      echo
      echo "# nmcli dev wifi list --rescan no:"
      nmcli dev wifi list --rescan no || echo "nmcli dev wifi list failed"

      echo
      echo "# nmcli device show ${WIFI_IFACE} (DNS properties):"
      nmcli device show "${WIFI_IFACE}" 2>/dev/null | grep -Ei 'IP4.DNS|IP4.DOMAIN|GENERAL.CONNECTION|GENERAL.STATE|IP4.GATEWAY' || echo "nmcli device show failed"

    fi

    if command_exists ss; then
      echo
      echo "# OpenVPN sockets (ss -tuna | grep -i openvpn):"
      ss -tuna | grep -i openvpn || echo "No OpenVPN sockets observed"
    fi

  # Journald logs around the event
    echo
    echo "# NetworkManager/wpa_supplicant logs (since ${since_when}):"
    journalctl --since "${since_when}" -u NetworkManager -u wpa_supplicant -o short-iso || true


    echo
    echo "# journalctl: OpenVPN-related lines (pattern search, since ${since_when}):"
    journalctl --since "${since_when}" -g 'openvpn' -o short-iso || true

    echo
    echo "# journalctl: SOCKET-MANAGER-related lines (pattern search, since ${since_when}):"
    journalctl --since "${since_when}" -g 'SOCKET-MANAGER' -o short-iso || true

    echo
    echo "# journalctl: noteable mentions since ${since_when}:"
    journalctl --since "${since_when}" -k -o short-iso | grep -Ei 'iwlwifi|ath|rtl|brcm|wlan|wlp' || true

    echo
    echo "# journalctl: kernel messages (since ${since_when}):"
    journalctl --since "${since_when}" -k -o short-iso || true

    # DNS resolution
    echo
    echo "# resolv.conf:"
    cat /etc/resolv.conf 2>/dev/null || echo "No /etc/resolv.conf readable"


    if command_exists resolvectl; then
      echo
      echo "# resolvectl status/statistics (systemd-resolved):"
      resolvectl status || echo "resolvectl status failed"
      echo
      resolvectl statistics || echo "resolvectl statistics failed"
    fi

    echo
    echo "# journalctl: systemd-resolved (since ${since_when}):"
    journalctl --since "${since_when}" -u systemd-resolved -o short-iso || true
    echo "# DNS details:"
    echo "## Public via system resolver:"
    dig +"time=${DNS_TIMEOUT}" +tries=1 "${PUBLIC_FQDN}" || true
    echo
    echo "## Public via explicit servers: ${PUBLIC_DNS_SERVER}"
    echo "### Server ${PUBLIC_DNS_SERVER}:"
    dig @"${PUBLIC_DNS_SERVER}" +"time=${DNS_TIMEOUT}" +tries=1 "${PUBLIC_FQDN}" || true
    echo

    if [[ -n "${VPN_FQDN}" ]]; then
      echo "## VPN FQDN via system resolver:"
      dig +"time=${DNS_TIMEOUT}" +tries=1 "${VPN_FQDN}" || true
      echo
      if [[ -n "${VPN_DNS_SERVER}" ]]; then
        echo "## VPN FQDN via VPN DNS servers: ${VPN_DNS_SERVER}"
        dig @"${VPN_DNS_SERVER}" +"time=${DNS_TIMEOUT}" +tries=1 "${VPN_FQDN}" || true
        echo
      fi
    fi
  } >> "$LOGFILE" 2>&1

  echo "" >> "$LOGFILE" 2>&1
  log "END SNAPSHOT"
}

dump_stats() {
  local link_out
  link_out="$(iw dev "${WIFI_IFACE}" link 2>/dev/null || true)"

  local wifi_connected="no"
  local wifi_ssid=""
  local wifi_signal=""
  local wifi_tx=""
  local wifi_rx=""

  if [[ "$link_out" =~ ^Connected ]]; then
    wifi_connected="yes"
    wifi_ssid="$(grep -E '^\s*SSID:' <<<"$link_out" | awk -F': ' '{print $2}')"
    wifi_signal="$(grep -E '^\s*signal:' <<<"$link_out" | awk -F': ' '{print $2}')"
    wifi_tx="$(grep -E '^\s*tx bitrate:' <<<"$link_out" | awk -F': ' '{print $2}')"
    wifi_rx="$(grep -E '^\s*rx bitrate:' <<<"$link_out" | awk -F': ' '{print $2}')"
  fi

  local gw; gw="$(wifi_gateway || true)"
  local gw_status="unknown"
  if [[ -n "${gw}" ]]; then
    if do_ping "${gw}" "" 1; then
      gw_status="pingable"
    else
      gw_status="unpingable"
    fi
  else
    gw_status="no-default-gw"
  fi

  if do_ping "${PUBLIC_DNS_SERVER}" "" 1; then
    pdnss="pingable"
  else 
    pdnss="unpingable"
  fi

  if do_ping "${PUBLIC_FQDN}" "" 1; then
    pfqdn="pingable"
  else
    pfqdn="unpingable"
  fi

  local vpn_iface_opt=""
  if [[ -n "${VPN_IFACE}" ]]; then
    vpn_iface_opt="${VPN_IFACE}"
  fi
  local vpn_status="unknown"
  if do_ping "${VPN_TARGET}" "${vpn_iface_opt}" 1; then
    vpn_status="pingable"
  else
    vpn_status="unpingable"
  fi
  fi

  # Check for routing table changes
  local route_hash_current
  route_hash_current=$(ip route 2>/dev/null | md5sum | cut -d' ' -f1 || echo "unknown")
  local route_changed="no"
  if [[ -n "${ROUTE_HASH_INITIAL}" && "${route_hash_current}" != "${ROUTE_HASH_INITIAL}" ]]; then
    route_changed="yes"
  fi

  # Formatted log output with proper field widths
  {
    echo "=== Network Status ==="
    printf "%-20s: %s\n" "WiFi Connected" "${wifi_connected}"
    printf "%-20s: %s\n" "SSID" "${wifi_ssid:-N/A}"
    printf "%-20s: %s\n" "Signal" "${wifi_signal:-N/A}"
    printf "%-20s: %s\n" "TX Bitrate" "${wifi_tx:-N/A}"
    printf "%-20s: %s\n" "RX Bitrate" "${wifi_rx:-N/A}"
    printf "%-20s: %s (%s)\n" "Gateway" "${gw:-N/A}" "${gw_status}"
    printf "%-20s: %s (%s)\n" "VPN Target" "${VPN_TARGET}" "${vpn_status}"
    if [[ -n "${vpn_ping_stats}" ]]; then
      printf "%-20s: %s\n" "VPN Ping Stats" "${vpn_ping_stats}"
    fi
    printf "%-20s: %s (%s)\n" "Public DNS" "${PUBLIC_DNS_SERVER}" "${pdnss}"
    printf "%-20s: %s (%s)\n" "Public FQDN" "${PUBLIC_FQDN}" "${pfqdn}"
    printf "%-20s: %s\n" "Route Changed" "${route_changed}"
    echo "======================"
  } | tee -a "$LOGFILE"

  # ---- VPN reachability failure; snapshot ----
  if [[ "${vpn_status}" == "unpingable" || "${wifi_connected}" == "no" ]]; then
    log "Detected reachability failure. Dumping diagnostics..."
    dump_diagnostics
  fi
}

# 01M01
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target) VPN_TARGET="$2"; shift 2;;
    -w|--wifi) WIFI_IFACE="$2"; shift 2;;
    -v|--vpn) VPN_IFACE="$2"; shift 2;;
    -i|--interval) INTERVAL_SEC="$2"; shift 2;;
    -s|--since) SINCE_WINDOW="$2"; shift 2;;
    -o|--outdir) LOG_DIR="$2"; shift 2;;
    -f|--fqdn) VPN_FQDN="$2"; shift 2;;
    -d|--dns) VPN_DNS_SERVER="$2"; shift 2;;
    -p|--public) PUBLIC_FQDN="$2"; shift 2;;
    --public-dns) PUBLIC_DNS_SERVER="$2"; shift 2;;
    --dns-timeout) DNS_TIMEOUT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

if [[ -z "${VPN_TARGET}" ]]; then
  echo "ERROR: Required param -t/--target <VPN_INTERNAL_IP> not specified"
  usage
  exit 1
fi

mkdir -p "${LOG_DIR}"
LOGFILE="${LOG_DIR}/vpn_wifi_diag_$(date +%Y%m%d_%H%M%S).log"

log "Starting VPN/wifi diagnostic monitor."
log "Target inside VPN: ${VPN_TARGET}"
log "Interval: ${INTERVAL_SEC}s, Journald window on failure: '${SINCE_WINDOW}'"
log "VPN-only FQDN: '${VPN_FQDN:-<none>}' | VPN DNS servers: '${VPN_DNS_SERVER:-<none>}' | Public FQDN: '${PUBLIC_FQDN}' | Public DNS servers: '${PUBLIC_DNS_SERVER}'"
log "Logs will be captured to: ${LOGFILE}"

detect_wifi_iface
detect_vpn_iface

# Capture initial routing table hash for change detection
ROUTE_HASH_INITIAL=$(ip route 2>/dev/null | md5sum | cut -d' ' -f1 || echo "unknown")
log "Initial routing table hash: ${ROUTE_HASH_INITIAL}"

log "Monitoring started. Press Ctrl+C to stop."
trap 'log "Stopping monitor."; exit 0' INT TERM

while true; do
  dump_stats
  sleep "${INTERVAL_SEC}"
done

