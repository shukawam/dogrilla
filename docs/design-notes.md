# 設計メモ

なぜこの構成なのか、実測で分かったことの記録です。日付付きの実測は Kong AI Gateway 2.3.0〜2.3.1、kongctl 1.26.0、Claude Code 2.1.326、Codex CLI 0.167.1 でのものです。

## Codex CLI

```bash
codex-kong -m gpt-6-luna
```

`~/.codex/config.toml` は書き換えず、`bin/codex-kong` が `-c` で接続先だけ上書きします。素の `codex` は今までどおり直結です。

```
Codex CLI（ChatGPT ログイン）
  │  http://localhost:18000/codex/responses   Authorization: Bearer <ChatGPT のトークン>、chatgpt-account-id、apikey: <Virtual Key>
  ▼
Kong AI Gateway DP（compose の kong）   本文の model で Model を選ぶ
  │  http://codex-upstream:8080/backend-api/codex/responses（compose のネットワーク内だけ）
  ▼
OpenResty（compose の codex-upstream）   Content-Type を補い、完了イベントの直後に応答を閉じる
  ▼
https://chatgpt.com/backend-api/codex/responses
```

- `requires_openai_auth = true` のプロバイダーには、ChatGPT ログインのトークン（`Authorization`）と `chatgpt-account-id` がそのまま送られます（ヘッダー名だけ記録するローカルのサーバーで実測）。Virtual Key は `env_http_headers` で `apikey` に載せます。
- 中継（OpenResty）を挟む理由は 2 つで、どちらも Kong AI Gateway 2.3.0 がこの上流をそのままでは集計できないためです（`codex-upstream/nginx.conf`）。2.3.1 で直っているかは未確認です。
  - `chatgpt.com/backend-api/codex` は SSE の応答に `Content-Type` を付けません。Kong はそれが無いと、openai 形式ではストリームを切り（`normalize-sse-chunk.lua:252` の `ipairs(nil)`）、passthrough では usage の読み取りを飛ばします。
  - Codex は `response.completed` を受け取るとすぐ接続を切ります。上流がまだ応答を閉じていないと、Kong のログに `client prematurely closed connection` が出て、コストのイベントが Konnect に出ません。中継が完了イベントの直後に応答を閉じると、イベントにトークン数と金額が付きました（2026-11-17 に実測。`gpt-6-luna` の 2 リクエストで $0.0017 と $0.0002）。
- passthrough にしない理由：`Content-Type` を補っても、passthrough の usage 解析は Responses API のストリーム（usage が `response` の下にある）を読めません。
- passthrough の Model で `upstream_url` に path を付けると、Kong はリクエストの残りのパスを捨てて、その path だけを叩きます。
- Codex は起動時に `GET /codex/models` を送り、Kong は 404 を返します（Model は `POST /responses` だけ）。Codex は手元のモデル一覧で動くので実害はありません。
- `config/kongctl.yaml` に無いモデル ID を使うと 500 になります。

## Konnect のエンティティ

宣言的に書けるものはすべて `config/kongctl.yaml` にあります。

| エンティティ | 名前 | 要点 |
| --- | --- | --- |
| AI Gateway | `<PREFIX>-agent-gateway` | hybrid、`min_runtime_version: 2.3` |
| AI Model Provider | `anthropic-subscription-passthrough`、`chatgpt-subscription-passthrough` | `auth: {type: basic}` でヘッダーなし（Kong は何も注入しない） |
| AI Auth Strategy | `virtual-key-auth` | key-auth、`key_names: [apikey]`、`hide_credentials: true`、`principals.enabled: true`（directory `default`） |
| AI Model（Claude） | `claude-fable-5-2`、`claude-opus-5-5`、`claude-sonnet-5-5`、`claude-haiku-5-5`、`claude-opus-5`、`claude-sonnet-5` | anthropic 形式、path `/claude`、本文の `model` で振り分け、`logging.payloads: false`、target に `allow_auth_override: true`。Model 名 = target 名 = Anthropic のモデル ID |
| AI Model（Codex） | `gpt-6-astra`、`gpt-6.1-sol`、`gpt-6-sol`、`gpt-6.1-terra`、`gpt-6-luna`、`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna` | openai 形式、`capabilities: [agentic]`、path `/codex`、上流は compose 内の `codex-upstream`、`allow_auth_override: true` |
| Virtual Key | 利用者ごとに 1 つ（Claude Code と Codex で共用） | Kong Identity の Principal（directory `default`）に `mise run virtual-key` で発行。値は `.env` の `KONG_VIRTUAL_KEY` か、`KONG_VIRTUAL_KEY_OP_REF` が指す 1Password |
| Attribution | `ai-cost-attribution`（global policy） | `integrations: ["claude-code", "codex"]` |

Attribution と Virtual Key は宣言的に書けないので、`scripts/konnect.sh` が API で作ります（画面なら AI > Cost Management > Attribution のトグルと、AI > Access Management > Virtual Keys）。

AI Consumer は使っていません。Cost Management の帰属先（subject）は Kong Identity の Principal なので、Virtual Key を Principal に解決する方式にしています。Virtual Key は AI Gateway ではなく Directory に属するので、Gateway を作り直しても発行し直す必要はありません。

```bash
curl -X PUT "https://us.api.konghq.com/v1/ai-cost-management/ai-gateways/$AIGW_ID/attribution-plugin" \
  -H "Authorization: Bearer $KONNECT_PAT" -H 'content-type: application/json' \
  -d '{"integrations":["claude-code","codex"]}'
```

DP は `KONG_CUSTOM_PLUGIN_STREAMING_ENABLED=on` で起動します。Attribution のトグルが Conflict になるときは、この設定を持たない DP が残っています（止めた DP も数分は一覧に残ります）。Attribution を外すときは、必ず先にトグルを無効にしてください。attribution plugin が残ったまま streaming が off の DP をつなぐと、その DP は設定全体を受け取れなくなります。

## 検証で分かったこと

| # | 問い | 結論 |
| --- | --- | --- |
| 1 | 「Provided by client or agent」を kongctl / API でどう表すか | 専用の値は無い。Provider は `config.auth: {type: basic}`（`headers` なし）、Model の target に `allow_auth_override: true`。この組み合わせで、Max の OAuth トークンが上流に届いて 200 が返ることを確認済み（2026-11-17）。UI の表示との照合は未実施 |
| 2 | passthrough が `anthropic-beta` などを変更せずに転送するか | passthrough では転送された（Max の Claude Code 2.1.326 が 200。2026-11-17）。コストを取るために anthropic 形式へ切り替え、anthropic 形式でも Max のトークンで 200 が返る（2026-11-18） |
| 3 | key-auth が上流転送時に `apikey` を外せるか | `hide_credentials: true` で外せる |
| 4 | `ai-cost-scm-*` のヘッダー名 | `ai-cost-<タグ名>` の規則どおりで正しい。イベントに `scm-provider=github`、`scm-repository=<owner>/<repo>`、`scm-branch=main` が付いた（2026-11-17）。Konnect の画面に Header builder は無い |
| 5 | サブスクリプション経由のコスト表示 | passthrough では $0（`reported_cost: 0`）。イベントの model が target 名になり、単価を引けない。モデル ID ごとに anthropic 形式の Model を分け、Model 名と target 名をモデル ID に合わせると、DP の `missing price` の警告は消えた。Konnect 上で API 換算額が付くかは未確認。付いても実際の請求額ではない |

- 帰属は `subject: principal/<Principal の ID>`、ハーネスは `client: claude_code` で記録されます。`agent-session`、`agent-request-kind`（`main` / `background`）、`agent-version` のタグも付きます（2026-11-17 に実測）。
- `agent-request-kind` と `agent-type` のタグは `CLAUDE_CODE_GATEWAY_HINT_HEADERS=1` のときだけ付きます（`mise/claude-via-kong.sh` で設定済み）。
- DP のログに出る `bearer token is not a JWT; no identity claims read` は、attribution plugin が Max の OAuth トークンから利用者を読めなかったという通知で、トークンの値は出ません。帰属は Virtual Key 側で決まるので無視できます。
- DP のログに大量に出る `failed to parse native response format for analytics` は info レベルで、応答とイベントの記録には影響していません。
- passthrough の Model では `config.route.model`（モデル名でのルーティング）が 400 で拒否されます（`model aliases are not supported with the passthrough format`）。
- モデル名で振り分ける Model と、振り分けない受け皿の Model は、同じ path に同居できません。どの `values` にも当たらないリクエストは受け皿に届かず 500（`ai-gateway.upstream.local` の DNS 失敗）になります。DP のログで 500 を見つけたら、そのモデル ID の Model を `config/kongctl.yaml` に足します。

## トラブルシュート

**DP が Konnect に繋がらない。** `mise run sync` が成功し、`.certs/cluster.crt` が Konnect に登録されているか確認してください。クラスタ証明書を作り直すときは `.certs/` を消して `mise run sync` で再登録し、`mise run down && mise run up` で DP に読み直させてください。

**`CONTROL_PLANE_ID` が空。** compose が起動前にエラーで止めます。`mise run sync` を実行すると `.env` に書かれます。

