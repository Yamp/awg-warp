#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"
cd "$ROOT_DIR"

ipv4_pattern='([0-9]{1,3}\.){3}[0-9]{1,3}'
secret_pattern='(PrivateKey|PublicKey)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{20,}={0,2}|SERVER_ENDPOINT:[[:space:]]*"[^"$]'
awg_param_pattern='(J_C|J_MIN|J_MAX|S[1-4]|H[1-4])="\$\{(J_C|J_MIN|J_MAX|S[1-4]|H[1-4]):-[0-9]+'

exclude_paths=(
  ':!tests/repository-hygiene.sh'
)

found=0

if git grep -n -I -E "$ipv4_pattern|$secret_pattern|$awg_param_pattern" -- "${exclude_paths[@]}"; then
  printf 'Tracked files contain hardcoded IP addresses or key material.\n' >&2
  found=1
fi

while IFS= read -r commit; do
  if git grep -n -I -E "$ipv4_pattern|$secret_pattern|$awg_param_pattern" "$commit" -- "${exclude_paths[@]}"; then
    printf 'Git history contains hardcoded IP addresses or key material in %s.\n' "$commit" >&2
    found=1
  fi
done < <(git rev-list --all)

exit "$found"
