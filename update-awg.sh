#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)}"
STATE_FILE="${PROJECT_DIR}/data/awg-update-state.env"
GO_REPO="https://github.com/amnezia-vpn/amneziawg-go.git"
TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools.git"
BRANCH="${AMNEZIAWG_BRANCH:-master}"

cd "$PROJECT_DIR"
mkdir -p "$(dirname "$STATE_FILE")"

remote_sha() {
  local repo="$1"
  git ls-remote "$repo" "refs/heads/${BRANCH}" | awk '{print $1}'
}

current_go_sha="$(remote_sha "$GO_REPO")"
current_tools_sha="$(remote_sha "$TOOLS_REPO")"

if [[ -z "$current_go_sha" || -z "$current_tools_sha" ]]; then
  echo "Failed to resolve upstream AmneziaWG refs." >&2
  exit 1
fi

last_go_sha=""
last_tools_sha=""
if [[ -s "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

if [[ "$last_go_sha" == "$current_go_sha" && "$last_tools_sha" == "$current_tools_sha" ]]; then
  echo "No AmneziaWG updates: go=${current_go_sha}, tools=${current_tools_sha}"
  exit 0
fi

image_go_ref="$(docker image inspect local/awg-warp-awg:latest --format '{{ index .Config.Labels "awg-warp.amneziawg-go-ref" }}' 2>/dev/null || true)"
image_tools_ref="$(docker image inspect local/awg-warp-awg:latest --format '{{ index .Config.Labels "awg-warp.amneziawg-tools-ref" }}' 2>/dev/null || true)"

if [[ -z "$last_go_sha" && -z "$last_tools_sha" \
   && "$image_go_ref" == "$current_go_sha" \
   && "$image_tools_ref" == "$current_tools_sha" ]]; then
  {
    printf 'last_go_sha=%q\n' "$current_go_sha"
    printf 'last_tools_sha=%q\n' "$current_tools_sha"
  } > "$STATE_FILE"
  echo "Initialized update state without restart: go=${current_go_sha}, tools=${current_tools_sha}"
  exit 0
fi

echo "AmneziaWG update detected:"
echo "  amneziawg-go:    ${last_go_sha:-unknown} -> ${current_go_sha}"
echo "  amneziawg-tools: ${last_tools_sha:-unknown} -> ${current_tools_sha}"

docker compose build --pull --no-cache \
  --build-arg "AMNEZIAWG_GO_REF=${current_go_sha}" \
  --build-arg "AMNEZIAWG_TOOLS_REF=${current_tools_sha}" \
  awg
docker compose up -d --no-deps --force-recreate awg
docker image prune -f --filter "label=awg-warp.role=awg" >/dev/null 2>&1 || true

{
  printf 'last_go_sha=%q\n' "$current_go_sha"
  printf 'last_tools_sha=%q\n' "$current_tools_sha"
} > "$STATE_FILE"
