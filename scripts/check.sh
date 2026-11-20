#!/usr/bin/env bash
# usage: scripts/check.sh <doctor|smoke>
set -uo pipefail
# shellcheck source=../lib/env.sh
. "$(dirname "$(readlink -f "$0")")/../lib/env.sh"

fail=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
ng()   { printf '  NG    %s\n' "$*"; fail=1; }

doctor() {
  echo "tools"
  for c in docker kongctl jq curl openssl envsubst; do
    command -v "$c" >/dev/null && ok "$c" || ng "$c がありません（mise install / brew install gettext など）"
  done
  for c in claude codex op; do
    command -v "$c" >/dev/null && ok "$c" || warn "$c がありません（使うときだけ必要）"
  done
  docker info >/dev/null 2>&1 && ok "docker daemon" || ng "docker が起動していません"

  echo ".env"
  if [ ! -f "$ENV_FILE" ]; then
    ng ".env がありません（cp .env.example .env）"
  else
    [ -n "$(env_get PREFIX)" ] && ok "PREFIX=$(env_get PREFIX)" || ng "PREFIX が空"
    if [ -z "$(env_get KONNECT_PAT)" ]; then
      ng "KONNECT_PAT が空"
    elif curl -sf -o /dev/null "$(konnect_api)/v2/users/me" -H "Authorization: Bearer $(env_get KONNECT_PAT)"; then
      ok "KONNECT_PAT は有効（$(konnect_api)）"
    else
      ng "KONNECT_PAT で $(konnect_api) に認証できません（期限切れかリージョン違い）"
    fi
    [ -n "$(env_get CONTROL_PLANE_ID)" ] && ok "CONTROL_PLANE_ID" || warn "CONTROL_PLANE_ID が空（mise run setup で入る）"
    [ -n "$(env_get KONG_VIRTUAL_KEY)$(env_get KONG_VIRTUAL_KEY_OP_REF)" ] && ok "Virtual Key" || warn "Virtual Key が未設定（mise run virtual-key）"
  fi

  echo "環境変数（残っているとサブスクリプションではなく API 課金になる。claude-kong / codex-kong は自分で外す）"
  for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY; do
    [ -n "${!v:-}" ] && warn "$v が設定されています" || ok "$v なし"
  done
  return $fail
}

smoke() {
  local p b key code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$(status_url)/status")
  [ "$code" = 200 ] && ok "status $code" || ng "status $code（kong-up logs で確認）"

  p="$(proxy_url)/claude/v1/messages"
  b='{"model":"claude-haiku-5-5","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$p" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -d "$b")
  [ "$code" = 401 ] && ok "Virtual Key なしは Kong が 401" || ng "Virtual Key なしで $code（401 のはず）"

  # Authorization を付けないので、Kong を通過すれば Anthropic が 401 を返す。Kong の 401 との区別は本文で行う
  key=$(resolve_virtual_key)
  b=$(curl -s -X POST "$p" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -H "apikey: $key" -d "$b")
  case "$b" in
    *authentication_error*|*x-api-key*) ok "Virtual Key ありは Kong を通過して Anthropic まで届く" ;;
    *) ng "想定外の応答: $b" ;;
  esac
  return $fail
}

case "${1:-}" in
  doctor) doctor ;;
  smoke) smoke ;;
  *) die "usage: $0 <doctor|smoke>" ;;
esac
