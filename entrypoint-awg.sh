#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
AWG_IF="${AWG_IF:-awg0}"
WARP_IF="${WARP_IF:-warp}"
AWG_PORT="${AWG_PORT:-51820}"
AWG_SUBNET="${AWG_SUBNET:-}"
AWG_SERVER_ADDR="${AWG_SERVER_ADDR:-}"
AWG_CLIENT_ADDR="${AWG_CLIENT_ADDR:-}"
AWG_MTU="${AWG_MTU:-1280}"
WARP_TABLE="${WARP_TABLE:-51820}"
SERVER_ENDPOINT="${SERVER_ENDPOINT:-}"
CLIENT_DNS="${CLIENT_DNS:-}"
CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS:-}"

J_C="${J_C:-}"
J_MIN="${J_MIN:-}"
J_MAX="${J_MAX:-}"
S1="${S1:-}"
S2="${S2:-}"
S3="${S3:-}"
S4="${S4:-}"
H1="${H1:-}"
H2="${H2:-}"
H3="${H3:-}"
H4="${H4:-}"

log() {
  printf '[awg] %s\n' "$*" >&2
}

require_config() {
  local missing=0
  local name
  for name in \
    AWG_SUBNET AWG_SERVER_ADDR AWG_CLIENT_ADDR CLIENT_DNS CLIENT_ALLOWED_IPS \
    J_C J_MIN J_MAX S1 S2 S3 S4 H1 H2 H3 H4; do
    if [[ -z "${!name:-}" ]]; then
      log "Required environment variable ${name} is missing. Run ./install.sh to generate .env."
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

wait_for_warp() {
  for _ in $(seq 1 60); do
    if ip link show "$WARP_IF" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  log "WARP interface ${WARP_IF} did not appear."
  exit 1
}

detect_endpoint() {
  if [[ -n "$SERVER_ENDPOINT" ]]; then
    printf '%s\n' "$SERVER_ENDPOINT"
    return
  fi

  local public_ip route_target
  public_ip="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
  if [[ -z "$public_ip" ]]; then
    route_target="$(getent ahostsv4 one.one.one.one | awk 'NR == 1 { print $1; exit }')"
    if [[ -n "$route_target" ]]; then
      public_ip="$(ip -4 route get "$route_target" | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    fi
  fi
  if [[ -z "$public_ip" ]]; then
    log "Unable to detect SERVER_ENDPOINT. Set it in .env and restart."
    exit 1
  fi
  printf '%s:%s\n' "$public_ip" "$AWG_PORT"
}

generate_awg_keys() {
  mkdir -p "$DATA_DIR"
  umask 077
  [[ -s "$DATA_DIR/server.key" ]] || awg genkey > "$DATA_DIR/server.key"
  [[ -s "$DATA_DIR/server.pub" ]] || awg pubkey < "$DATA_DIR/server.key" > "$DATA_DIR/server.pub"
  [[ -s "$DATA_DIR/client.key" ]] || awg genkey > "$DATA_DIR/client.key"
  [[ -s "$DATA_DIR/client.pub" ]] || awg pubkey < "$DATA_DIR/client.key" > "$DATA_DIR/client.pub"
}

generate_awg_config() {
  local endpoint
  endpoint="$(detect_endpoint)"

  cat > "/etc/amnezia/amneziawg/${AWG_IF}.conf" <<EOF
[Interface]
PrivateKey = $(<"$DATA_DIR/server.key")
Address = ${AWG_SERVER_ADDR}
ListenPort = ${AWG_PORT}
MTU = ${AWG_MTU}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = $(<"$DATA_DIR/client.pub")
AllowedIPs = ${AWG_CLIENT_ADDR}
EOF

  cat > "$DATA_DIR/client.conf" <<EOF
[Interface]
PrivateKey = $(<"$DATA_DIR/client.key")
Address = ${AWG_CLIENT_ADDR}
DNS = ${CLIENT_DNS}
MTU = ${AWG_MTU}
Jc = ${J_C}
Jmin = ${J_MIN}
Jmax = ${J_MAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = $(<"$DATA_DIR/server.pub")
Endpoint = ${endpoint}
AllowedIPs = ${CLIENT_ALLOWED_IPS}
PersistentKeepalive = 25
EOF

  chmod 600 "/etc/amnezia/amneziawg/${AWG_IF}.conf" "$DATA_DIR/client.conf"
  log "Client config is available at ${DATA_DIR}/client.conf"
}

delete_rules() {
  while iptables -t nat -D POSTROUTING -s "$AWG_SUBNET" -o "$WARP_IF" -j MASQUERADE >/dev/null 2>&1; do :; done
  while iptables -D FORWARD -i "$AWG_IF" -o "$WARP_IF" -j ACCEPT >/dev/null 2>&1; do :; done
  while iptables -D FORWARD -i "$WARP_IF" -o "$AWG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1; do :; done
  ip rule del from "$AWG_SUBNET" table "$WARP_TABLE" >/dev/null 2>&1 || true
  ip route flush table "$WARP_TABLE" >/dev/null 2>&1 || true
}

cleanup_existing() {
  awg-quick down "$AWG_IF" >/dev/null 2>&1 || true
  delete_rules
}

setup_routing() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  awg-quick up "$AWG_IF"

  ip route replace default dev "$WARP_IF" table "$WARP_TABLE"
  ip rule add from "$AWG_SUBNET" table "$WARP_TABLE" priority 1000 2>/dev/null || true

  iptables -t nat -C POSTROUTING -s "$AWG_SUBNET" -o "$WARP_IF" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$AWG_SUBNET" -o "$WARP_IF" -j MASQUERADE
  iptables -C FORWARD -i "$AWG_IF" -o "$WARP_IF" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$AWG_IF" -o "$WARP_IF" -j ACCEPT
  iptables -C FORWARD -i "$WARP_IF" -o "$AWG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$WARP_IF" -o "$AWG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

shutdown() {
  log "Stopping AWG."
  awg-quick down "$AWG_IF" >/dev/null 2>&1 || true
  delete_rules
}

main() {
  require_config
  wait_for_warp
  generate_awg_keys
  generate_awg_config
  cleanup_existing
  setup_routing

  trap shutdown EXIT INT TERM
  log "Ready. AWG listens on UDP ${AWG_PORT}; client traffic exits through WARP."
  tail -f /dev/null &
  wait $!
}

main "$@"
