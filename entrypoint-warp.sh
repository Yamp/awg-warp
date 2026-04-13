#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
WARP_IF="${WARP_IF:-warp}"

log() {
  printf '[warp] %s\n' "$*" >&2
}

require_tun() {
  if [[ ! -c /dev/net/tun ]]; then
    log "/dev/net/tun is missing. Run the container with --device /dev/net/tun."
    exit 1
  fi
}

generate_warp_config() {
  mkdir -p "$DATA_DIR"
  pushd "$DATA_DIR" >/dev/null
  if [[ ! -s wgcf-account.toml ]]; then
    log "Registering a new Cloudflare WARP account with wgcf."
    wgcf register --accept-tos
  fi
  if [[ ! -s wgcf-profile.conf ]]; then
    wgcf generate
  fi
  popd >/dev/null

  awk '
    /^\[Interface\]$/ { print; print "Table = off"; next }
    /^DNS[[:space:]]*=/ { next }
    { print }
  ' "$DATA_DIR/wgcf-profile.conf" > "/etc/wireguard/${WARP_IF}.conf"
  chmod 600 "/etc/wireguard/${WARP_IF}.conf"
}

cleanup_existing() {
  wg-quick down "$WARP_IF" >/dev/null 2>&1 || true
}

shutdown() {
  log "Stopping WARP."
  wg-quick down "$WARP_IF" >/dev/null 2>&1 || true
}

main() {
  require_tun
  generate_warp_config
  cleanup_existing
  wg-quick up "$WARP_IF"

  trap shutdown EXIT INT TERM
  log "Ready. WARP is up with Table=off."
  tail -f /dev/null &
  wait $!
}

main "$@"
