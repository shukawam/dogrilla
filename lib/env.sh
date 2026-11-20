# shellcheck shell=bash
# bin/ と scripts/ から source する

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ENV_FILE="$ROOT/.env"

# .env を丸ごと source しないのは、KONNECT_PAT を claude / codex のプロセスに渡さないため
env_get() {
  local key="$1" line
  [ -f "$ENV_FILE" ] || return 0
  line=$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)
  line="${line#*=}"
  line="${line%\"}"
  line="${line#\"}"
  printf '%s' "$line"
}

# 呼び出し側の環境変数を .env より優先する
env_or_file() {
  local key="$1"
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
  else
    env_get "$key"
  fi
}

env_set() {
  local key="$1" value="$2" tmp
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  tmp=$(mktemp "$ROOT/.env.XXXXXX")
  if grep -qE "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$value" 'index($0, k "=") == 1 { print k "=\"" v "\""; next } { print }' "$ENV_FILE" > "$tmp"
  else
    cat "$ENV_FILE" > "$tmp"
    printf '%s="%s"\n' "$key" "$value" >> "$tmp"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

die() {
  echo "error: $*" >&2
  exit 1
}

konnect_api() {
  local region
  region=$(env_or_file KONNECT_REGION)
  printf 'https://%s.api.konghq.com' "${region:-us}"
}

proxy_url() {
  local port
  port=$(env_or_file KONG_PROXY_PORT)
  printf 'http://localhost:%s' "${port:-18000}"
}

status_url() {
  local port
  port=$(env_or_file KONG_STATUS_PORT)
  printf 'http://localhost:%s' "${port:-18100}"
}

resolve_virtual_key() {
  local key ref
  key=$(env_or_file KONG_VIRTUAL_KEY)
  if [ -z "$key" ]; then
    ref=$(env_or_file KONG_VIRTUAL_KEY_OP_REF)
    if [ -n "$ref" ]; then
      key=$(op read "$ref") || die "1Password（$ref）から Virtual Key を読めませんでした"
    fi
  fi
  [ -n "$key" ] || die "Virtual Key がありません。mise run setup を実行するか、.env の KONG_VIRTUAL_KEY / KONG_VIRTUAL_KEY_OP_REF を設定してください"
  printf '%s' "$key"
}

compose() {
  # compose は .env より環境変数を優先する。呼び出し元（別プロジェクトの mise env など）の値で別 CP につながるのを防ぐ
  # サブシェルで cd するのは、compose.override.yaml を自動で拾わせるため（-f を明示すると拾わない）
  (cd "$ROOT" && env -u CONTROL_PLANE_ID -u KONNECT_REGION -u KONG_PROXY_PORT -u KONG_STATUS_PORT docker compose "$@")
}
