#!/usr/bin/env bash
# usage: scripts/konnect.sh <render|sync|diff|principals|virtual-key|attribution|setup> [args]
set -euo pipefail
# shellcheck source=../lib/env.sh
. "$(dirname "$(readlink -f "$0")")/../lib/env.sh"

PREFIX=$(env_or_file PREFIX)
PAT=$(env_or_file KONNECT_PAT)
API=$(konnect_api)
GATEWAY_NAME="${PREFIX}-agent-gateway"

require() {
  [ -f "$ENV_FILE" ] || die ".env がありません。cp .env.example .env して PREFIX と KONNECT_PAT を埋めてください"
  [ -n "$PAT" ] || die ".env の KONNECT_PAT が空です"
  [[ "$PREFIX" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die ".env の PREFIX は英小文字・数字・ハイフンにしてください（今の値: '$PREFIX'）"
}

api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --fail-with-body -X "$method" "$API$path" \
    -H "Authorization: Bearer $PAT" -H 'content-type: application/json' "$@"
}

render() {
  require
  # 変数を明示しないと、テンプレート中の他の $ も空文字に置き換わる
  PREFIX="$PREFIX" envsubst '${PREFIX}' < "$ROOT/config/kongctl.yaml.tmpl" > "$ROOT/config/kongctl.yaml"
}

kongctl_run() {
  render
  # kongctl は書き込み専用の秘密を比較しないので、--write-secrets 無しでは .env だけ変えても更新が走らない
  kongctl "$1" konnect -f "$ROOT/config/kongctl.yaml" --base-dir "$ROOT" --base-url "$API" --pat "$PAT" --write-secrets "${@:2}"
}

certs() {
  [ -f "$ROOT/.certs/cluster.crt" ] && return 0
  mkdir -p "$ROOT/.certs"
  openssl req -new -x509 -nodes -newkey rsa:2048 \
    -subj "/CN=${GATEWAY_NAME}" -addext "subjectAltName=DNS:${GATEWAY_NAME}" \
    -keyout "$ROOT/.certs/cluster.key" -out "$ROOT/.certs/cluster.crt" -days 1095 2>/dev/null
  chmod 600 "$ROOT/.certs/cluster.key"
  echo "クラスタ証明書を作成しました: .certs/" >&2
}

gateway_id() {
  kongctl get konnect ai-gateway "$GATEWAY_NAME" --base-url "$API" --pat "$PAT" -o json | jq -r '.id // empty'
}

save_control_plane_id() {
  local endpoint cp_id
  endpoint=$(kongctl get konnect ai-gateway "$GATEWAY_NAME" --base-url "$API" --pat "$PAT" -o json | jq -r '.endpoints.configuration // empty')
  cp_id=${endpoint#https://}
  cp_id=${cp_id%%.*}
  [ -n "$cp_id" ] || die "$GATEWAY_NAME のエンドポイントを取得できませんでした"
  env_set CONTROL_PLANE_ID "$cp_id"
  echo "CONTROL_PLANE_ID=$cp_id を .env に書きました" >&2
}

attribution() {
  require
  local id
  id=$(gateway_id)
  [ -n "$id" ] || die "$GATEWAY_NAME がありません。先に mise run sync を実行してください"
  # 宣言的に書けないので API で入れる。PUT なので何度実行してもよい
  api PUT "/v1/ai-cost-management/ai-gateways/$id/attribution-plugin" \
    -d '{"integrations":["claude-code","codex"]}' > /dev/null
  echo "Attribution（claude-code, codex）を有効にしました" >&2
}

directory_id() {
  api GET /v2/directories | jq -r '.data[] | select(.name == "default") | .id'
}

principals() {
  require
  local q="${1:-}" dir
  dir=$(directory_id)
  [ -n "$dir" ] || die "Kong Identity の directory 'default' が見つかりません"
  api GET "/v2/directories/$dir/principals?page%5Bsize%5D=100&filter%5Bdisplay_name%5D%5Bcontains%5D=$(jq -rn --arg q "$q" '$q|@uri')" \
    | jq -r '.data[] | [.id, .display_name, .provisioned_by] | @tsv'
}

virtual_key() {
  require
  local principal dir name resp key
  if [ -n "$(env_get KONG_VIRTUAL_KEY)" ] || [ -n "$(env_get KONG_VIRTUAL_KEY_OP_REF)" ]; then
    echo "Virtual Key は設定済みです（.env）。発行し直すときは KONG_VIRTUAL_KEY を空にしてください" >&2
    return 0
  fi
  principal=$(env_get PRINCIPAL_ID)
  if [ -z "$principal" ]; then
    echo "PRINCIPAL_ID が空なので Virtual Key の発行を飛ばしました。" >&2
    echo "  mise run principals -- <自分の名前の一部>  で ID を探して .env の PRINCIPAL_ID に書き、mise run virtual-key を実行してください" >&2
    return 0
  fi
  dir=$(directory_id)
  name="${GATEWAY_NAME}-$(hostname -s)"
  resp=$(api POST "/v2/directories/$dir/principals/$principal/api-keys" -d "$(jq -n --arg n "$name" '{type: "v1", name: $n}')")
  # secret は一度しか返らない。取り出せなかったときに失わないよう、応答を 600 で残す
  key=$(printf '%s' "$resp" | jq -r '.secret // .key // .value // .token // empty')
  if [ -z "$key" ]; then
    mkdir -p "$ROOT/.secrets" && chmod 700 "$ROOT/.secrets"
    (umask 077 && printf '%s\n' "$resp" > "$ROOT/.secrets/virtual-key-response.json")
    die "Virtual Key を応答から取り出せませんでした。.secrets/virtual-key-response.json の値を .env の KONG_VIRTUAL_KEY に書いてください"
  fi
  env_set KONG_VIRTUAL_KEY "$key"
  echo "Virtual Key（$name）を発行して .env に書きました" >&2
}

setup() {
  require
  command -v kongctl >/dev/null || die "kongctl がありません。mise install を実行してください"
  certs
  kongctl_run sync --auto-approve
  save_control_plane_id
  attribution
  virtual_key
  "$ROOT/bin/kong-up"
  echo "完了しました。mise run smoke で疎通を確認してください" >&2
}

cmd="${1:-}"
shift || true
case "$cmd" in
  render) render ;;
  sync) certs; kongctl_run sync --auto-approve "$@"; save_control_plane_id ;;
  diff) certs; kongctl_run diff "$@" ;;
  principals) principals "$@" ;;
  virtual-key) virtual_key ;;
  attribution) attribution ;;
  setup) setup ;;
  *) die "usage: $0 <render|sync|diff|principals|virtual-key|attribution|setup>" ;;
esac
