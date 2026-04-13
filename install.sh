#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
ENV_FILE="${ENV_FILE:-${PROJECT_DIR}/.env}"

log() {
  printf '[install] %s\n' "$*"
}

die() {
  printf '[install] %s\n' "$*" >&2
  exit 1
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "This installer supports Linux only."
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this installer as root."
}

rand_u32() {
  od -An -N4 -tu4 /dev/urandom | tr -d ' '
}

rand_range() {
  local min="$1"
  local max="$2"
  local span=$((max - min + 1))
  local value
  value="$(rand_u32)"
  printf '%s\n' $((min + value % span))
}

is_ipv4() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+){3}$ ]]
}

resolve_ipv4() {
  getent ahostsv4 "$1" | awk '$1 ~ /^[0-9]+([.][0-9]+){3}$/ { print $1; exit }'
}

detect_dns() {
  local dns
  dns="$(awk '/^nameserver[[:space:]]+/ && $2 ~ /^[0-9]+([.][0-9]+){3}$/ { print $2; exit }' /etc/resolv.conf || true)"
  if [[ -z "$dns" ]]; then
    dns="$(resolve_ipv4 cloudflare-dns.com || true)"
  fi
  [[ -n "$dns" ]] || die "Unable to detect a DNS server."
  printf '%s\n' "$dns"
}

detect_public_ip() {
  local public_ip service route_target
  for service in https://api.ipify.org https://ifconfig.me/ip; do
    public_ip="$(curl -4fsS --max-time 8 "$service" || true)"
    if is_ipv4 "$public_ip"; then
      printf '%s\n' "$public_ip"
      return
    fi
  done

  route_target="$(resolve_ipv4 one.one.one.one || true)"
  if [[ -n "$route_target" ]]; then
    public_ip="$(ip -4 route get "$route_target" | awk '{for (i=1;i<=NF;i++) if ($i=="src") { print $(i+1); exit }}')"
  fi
  if is_ipv4 "$public_ip"; then
    printf '%s\n' "$public_ip"
    return
  fi

  die "Unable to detect the public IPv4 address. Set SERVER_ENDPOINT manually in .env."
}

quote_env() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

write_env_var() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "$key" "$(quote_env "$value")"
}

load_existing_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
}

generate_env() {
  load_existing_env

  local existing_endpoint port public_ip net_a net_b net_c subnet_prefix zero zero_route env_tmp j_min
  existing_endpoint="${SERVER_ENDPOINT:-}"
  port="${AWG_PORT:-51820}"
  public_ip="${existing_endpoint%%:*}"
  if [[ -z "$public_ip" || "$public_ip" == "$existing_endpoint" ]]; then
    public_ip="$(detect_public_ip)"
  fi

  net_a="${AWG_NET_A:-10}"
  net_b="${AWG_NET_B:-$(rand_range 64 223)}"
  net_c="${AWG_NET_C:-$(rand_range 0 254)}"
  subnet_prefix="${net_a}.${net_b}.${net_c}"
  zero=0
  zero_route="${zero}.${zero}.${zero}.${zero}/0, ::/0"
  j_min="${J_MIN:-$(rand_range 8 32)}"

  env_tmp="$(mktemp)"
  {
    write_env_var AWG_PORT "$port"
    write_env_var SERVER_ENDPOINT "${existing_endpoint:-${public_ip}:${port}}"
    printf '\n'
    write_env_var AWG_SUBNET "${AWG_SUBNET:-${subnet_prefix}.0/24}"
    write_env_var AWG_SERVER_ADDR "${AWG_SERVER_ADDR:-${subnet_prefix}.1/24}"
    write_env_var AWG_CLIENT_ADDR "${AWG_CLIENT_ADDR:-${subnet_prefix}.2/32}"
    write_env_var CLIENT_DNS "${CLIENT_DNS:-$(detect_dns)}"
    write_env_var CLIENT_ALLOWED_IPS "${CLIENT_ALLOWED_IPS:-$zero_route}"
    printf '\n'
    write_env_var J_C "${J_C:-$(rand_range 3 10)}"
    write_env_var J_MIN "$j_min"
    write_env_var J_MAX "${J_MAX:-$(rand_range $((j_min + 16)) $((j_min + 96)))}"
    write_env_var S1 "${S1:-$(rand_range 16 255)}"
    write_env_var S2 "${S2:-$(rand_range 16 255)}"
    write_env_var S3 "${S3:-$(rand_range 16 255)}"
    write_env_var S4 "${S4:-$(rand_range 16 255)}"
    write_env_var H1 "${H1:-$(rand_range 1 2147483647)}"
    write_env_var H2 "${H2:-$(rand_range 1 2147483647)}"
    write_env_var H3 "${H3:-$(rand_range 1 2147483647)}"
    write_env_var H4 "${H4:-$(rand_range 1 2147483647)}"
    printf '\n'
    write_env_var AMNEZIAWG_GO_REF "${AMNEZIAWG_GO_REF:-master}"
    write_env_var AMNEZIAWG_TOOLS_REF "${AMNEZIAWG_TOOLS_REF:-master}"
  } > "$env_tmp"
  install -m 600 "$env_tmp" "$ENV_FILE"
  rm -f "$env_tmp"
  log "Wrote ${ENV_FILE}."
}

install_packages() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi
  if command -v docker >/dev/null 2>&1 && command -v docker-compose >/dev/null 2>&1; then
    return
  fi

  log "Installing Docker, Docker Compose, or missing base tools from the OS package manager."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y ca-certificates curl git docker.io docker-compose-plugin
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl git docker docker-compose-plugin
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl git docker docker-compose-plugin
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm ca-certificates curl git docker docker-compose
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install ca-certificates curl git docker docker-compose
  else
    die "No supported package manager found. Install Docker and rerun this script."
  fi
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    printf 'docker compose'
  elif command -v docker-compose >/dev/null 2>&1; then
    printf 'docker-compose'
  else
    die "Docker Compose is not available."
  fi
}

start_docker() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker
  elif command -v service >/dev/null 2>&1; then
    service docker start
  fi
}

install_systemd_units() {
  command -v systemctl >/dev/null 2>&1 || return

  install -m 644 "${PROJECT_DIR}/awg-auto-update.timer" /etc/systemd/system/awg-auto-update.timer
  cat > /etc/systemd/system/awg-auto-update.service <<EOF
[Unit]
Description=Rebuild and restart AmneziaWG container
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${PROJECT_DIR}
ExecStart=${PROJECT_DIR}/update-awg.sh
EOF
  systemctl daemon-reload
  systemctl enable --now awg-auto-update.timer
}

main() {
  require_linux
  require_root
  install_packages
  start_docker
  generate_env
  mkdir -p "${PROJECT_DIR}/data/awg" "${PROJECT_DIR}/data/warp"
  install_systemd_units

  local compose
  compose="$(compose_cmd)"
  cd "$PROJECT_DIR"
  $compose up -d --build

  log "AWG over WARP is installed."
  log "Client config will be written to ${PROJECT_DIR}/data/awg/client.conf."
}

main "$@"
