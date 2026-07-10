#!/usr/bin/env bash
# ==========================================================================
#  pirouter shared library
#  Sourced by all pirouter-* tools. Provides config IO + helpers.
# ==========================================================================

CONF="/etc/pirouter/pirouter.conf"
VLESS_STORE="/etc/pirouter/vless.list"   # lines: name<TAB>vless://...
MAC_STORE="/etc/pirouter/mac.list"       # lines: name<TAB>MAC
VLESS_MAX=5
STATE_DIR="/run/pirouter"
LOG="/var/log/pirouter.log"          # full activity log (all levels)
ERRLOG="/var/log/pirouter-error.log" # errors + warnings only
LOG_MAX_BYTES=$((512 * 1024))        # rotate each log past ~512 KB

# tag used in log lines to identify which tool wrote them
PR_TAG="${PR_TAG:-$(basename "${0:-pirouter}")}"

mkdir -p "$STATE_DIR" 2>/dev/null

# keep logs from growing without bound
_rotate_log() {
  local f="$1"
  [ -f "$f" ] || return 0
  local sz
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$LOG_MAX_BYTES" ]; then
    mv -f "$f" "${f}.1" 2>/dev/null || true
  fi
}

# _write LEVEL MESSAGE  -> timestamped line into $LOG (+ $ERRLOG for WARN/ERROR)
_write() {
  local level="$1"; shift
  local line
  line="$(date '+%F %T') [${level}] [${PR_TAG}] $*"
  _rotate_log "$LOG"
  echo "$line" >>"$LOG" 2>/dev/null
  case "$level" in
    ERROR|WARN)
      _rotate_log "$ERRLOG"
      echo "$line" >>"$ERRLOG" 2>/dev/null
      ;;
  esac
}

# log()      -> INFO to activity log, also echo to stdout (back-compat)
log()      { _write INFO  "$*"; echo "$*"; }
log_info() { _write INFO  "$*"; }
log_warn() { _write WARN  "$*"; echo "WARN: $*" >&2; }
log_err()  { _write ERROR "$*"; echo "ERROR: $*" >&2; }

# run_logged "description" cmd args...  -> run a command, capture its output and
# exit code into the logs. Returns the command's own exit code.
run_logged() {
  local desc="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    _write INFO "OK: ${desc}"
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /' >>"$LOG" 2>/dev/null
  else
    _write ERROR "FAILED (rc=${rc}): ${desc}"
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /' | tee -a "$LOG" >>"$ERRLOG" 2>/dev/null
  fi
  return "$rc"
}

# install a trap that records the failing line/command into the error log.
# Call `enable_error_trap` right after sourcing in tools that use `set -e`/`-u`.
enable_error_trap() {
  trap '_write ERROR "unexpected failure (rc=$?) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}"' ERR
}

die() { log_err "$*"; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
}

load_conf() {
  [ -f "$CONF" ] || die "config not found: $CONF"
  # shellcheck disable=SC1090
  source "$CONF"
}

# set_conf KEY VALUE  -> persist a value into the config file (chmod 600 kept)
set_conf() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$CONF"; then
    # escape / and & for sed replacement
    local esc
    esc=$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')
    sed -i "s/^${key}=.*/${key}=\"${esc}\"/" "$CONF"
  else
    echo "${key}=\"${val}\"" >>"$CONF"
  fi
  harden_conf
}

# make sure secrets (Wi-Fi/VPN/proxy passwords, VLESS links) are not world-readable
harden_conf() {
  chmod 600 "$CONF" 2>/dev/null || true
  [ -f "$VLESS_STORE" ] && chmod 600 "$VLESS_STORE" 2>/dev/null || true
  [ -f "$MAC_STORE" ]   && chmod 600 "$MAC_STORE"   2>/dev/null || true
}

valid_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.; local -a o=($ip)
  for n in "${o[@]}"; do [ "$n" -le 255 ] || return 1; done
  return 0
}

valid_mac() {
  [[ "$1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

# random locally-administered unicast MAC
random_mac() {
  printf '02:%02x:%02x:%02x:%02x:%02x\n' \
    $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) \
    $((RANDOM%256)) $((RANDOM%256))
}

# is a network interface up with an ipv4?
iface_has_ip() {
  ip -4 addr show dev "$1" 2>/dev/null | grep -q "inet "
}

# name of the active VPN tunnel interface, empty if none up
vpn_tun_iface() {
  load_conf
  case "$ACTIVE_VPN" in
    openvpn) ip link show tun0 &>/dev/null && echo tun0 ;;
    l2tp)    ip link show ppp0 &>/dev/null && echo ppp0 ;;
    vless|proxy) systemctl is-active --quiet xray && echo "xray" ;;
    *) echo "" ;;
  esac
}

is_service_active() { systemctl is-active --quiet "$1"; }

# WAN subnet currently assigned to $WAN_IF (e.g. 192.168.1.0/24), empty if none
wan_subnet() {
  local cidr
  cidr=$(ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -1)
  [ -n "$cidr" ] || return 1
  python3 - "$cidr" <<'PY' 2>/dev/null
import sys, ipaddress
print(ipaddress.ip_interface(sys.argv[1]).network.with_prefixlen)
PY
}

# subnet_conflict LAN_IP LAN_CIDR WAN_IF
# returns 0 (true) when the LAN subnet overlaps the WAN subnet -> conflict
subnet_conflict() {
  local wan_cidr
  wan_cidr=$(ip -4 -o addr show dev "$3" 2>/dev/null | awk '{print $4}' | head -1)
  [ -n "$wan_cidr" ] || return 1
  python3 - "$1/$2" "$wan_cidr" <<'PY' 2>/dev/null
import sys, ipaddress
a = ipaddress.ip_interface(sys.argv[1]).network
b = ipaddress.ip_interface(sys.argv[2]).network
sys.exit(0 if a.overlaps(b) else 1)
PY
}

# suggest a LAN /24 that does not collide with the given WAN subnet
suggest_lan_subnet() {
  local wan_if="$1" c
  for c in 33 42 77 88 133 144 177 188; do
    if ! subnet_conflict "192.168.${c}.1" 24 "$wan_if"; then
      echo "192.168.${c}.1"; return 0
    fi
  done
  echo "10.33.33.1"
}

# ==========================================================================
#  VLESS profile store  (up to $VLESS_MAX named vless:// links)
#  File format: one profile per line, "name<TAB>vless://..."
# ==========================================================================
vless_count() { [ -f "$VLESS_STORE" ] && grep -cve '^[[:space:]]*$' "$VLESS_STORE" || echo 0; }

# print "name" of each profile, one per line (index = line number)
vless_names() { [ -f "$VLESS_STORE" ] && cut -f1 "$VLESS_STORE" || true; }

# vless_url_by_name NAME -> prints the stored link
vless_url_by_name() {
  [ -f "$VLESS_STORE" ] || return 1
  awk -F'\t' -v n="$1" '$1==n{print $2; found=1} END{exit !found}' "$VLESS_STORE"
}

# vless_add NAME URL  -> add/replace a profile (enforces the max count)
vless_add() {
  local name="$1" url="$2"
  [ -n "$name" ] && [ -n "$url" ] || { log_err "vless_add: empty name/url"; return 1; }
  [[ "$url" == vless://* ]] || { log_err "vless_add: not a vless:// link"; return 1; }
  touch "$VLESS_STORE"; harden_conf
  # replacing an existing name is always allowed; adding new respects the cap
  if ! grep -qP "^${name}\t" "$VLESS_STORE" 2>/dev/null; then
    if [ "$(vless_count)" -ge "$VLESS_MAX" ]; then
      log_err "vless_add: limit of $VLESS_MAX profiles reached"; return 2
    fi
  fi
  local tmp; tmp="$(mktemp)"
  grep -vP "^${name}\t" "$VLESS_STORE" 2>/dev/null >"$tmp" || true
  printf '%s\t%s\n' "$name" "$url" >>"$tmp"
  mv -f "$tmp" "$VLESS_STORE"; harden_conf
  log_info "vless profile saved: $name"
}

# vless_del NAME
vless_del() {
  [ -f "$VLESS_STORE" ] || return 0
  local tmp; tmp="$(mktemp)"
  grep -vP "^${1}\t" "$VLESS_STORE" >"$tmp" || true
  mv -f "$tmp" "$VLESS_STORE"; harden_conf
  log_info "vless profile deleted: $1"
}

# vless_select NAME  -> make this profile the active VLESS link
vless_select() {
  local url; url="$(vless_url_by_name "$1")" || { log_err "vless_select: no profile $1"; return 1; }
  set_conf VLESS_URL "$url"
  set_conf VLESS_ACTIVE "$1"
  log_info "vless profile selected: $1"
}

# ==========================================================================
#  MAC profile store  (named MAC addresses you can re-apply to wifi/wan)
#  File format: "name<TAB>MAC"
# ==========================================================================
mac_names() { [ -f "$MAC_STORE" ] && cut -f1 "$MAC_STORE" || true; }
mac_by_name() {
  [ -f "$MAC_STORE" ] || return 1
  awk -F'\t' -v n="$1" '$1==n{print $2; found=1} END{exit !found}' "$MAC_STORE"
}
mac_profile_add() {
  local name="$1" mac="$2"
  valid_mac "$mac" || { log_err "mac_profile_add: invalid MAC $mac"; return 1; }
  touch "$MAC_STORE"; harden_conf
  local tmp; tmp="$(mktemp)"
  grep -vP "^${name}\t" "$MAC_STORE" 2>/dev/null >"$tmp" || true
  printf '%s\t%s\n' "$name" "$mac" >>"$tmp"
  mv -f "$tmp" "$MAC_STORE"; harden_conf
  log_info "mac profile saved: $name -> $mac"
}
mac_profile_del() {
  [ -f "$MAC_STORE" ] || return 0
  local tmp; tmp="$(mktemp)"
  grep -vP "^${1}\t" "$MAC_STORE" >"$tmp" || true
  mv -f "$tmp" "$MAC_STORE"; harden_conf
}

# ==========================================================================
#  Connectivity tests
# ==========================================================================
# test_ping HOST [COUNT]  -> prints a human summary, returns ping's exit code
test_ping() {
  local host="${1:-1.1.1.1}" cnt="${2:-4}" out rc
  out=$(ping -c "$cnt" -W 2 "$host" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    local rtt loss
    rtt=$(printf '%s' "$out" | awk -F'/' '/rtt|round-trip/{print $5" ms avg"}')
    loss=$(printf '%s' "$out" | awk -F',' '/packet loss/{gsub(/^ /,"",$3); print $3}')
    echo "OK  ${host}: ${rtt:-reachable}, ${loss:-}"
  else
    echo "FAIL ${host}: unreachable"
  fi
  return "$rc"
}

# pub_ip [SOCKS_HOST:PORT]  -> print the public IP as seen by the internet.
# With no arg it uses the Pi's default route; with a socks arg it goes through
# that SOCKS proxy (used to verify the VLESS/proxy tunnel actually carries traffic).
pub_ip() {
  local via="${1:-}" args=(-fsS --max-time 8)
  [ -n "$via" ] && args+=(--socks5-hostname "$via")
  local ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl "${args[@]}" "$url" 2>/dev/null | tr -d '[:space:]')
    [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] && [ -n "$ip" ] && { echo "$ip"; return 0; }
  done
  return 1
}
