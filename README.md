# kong-agent-gateway

個人のサブスクリプション（Claude Max、ChatGPT）で動く Claude Code と Codex CLI のリクエストをローカルの Kong AI Gateway に通し、Konnect の AI Cost Management で利用者（Principal）・セッション・リポジトリ単位に見るための環境です。サブスクリプションのログインはそのまま上流に届くので、API 課金にはなりません。

```
Claude Code / Codex CLI（各自のログインのまま）
  │  http://localhost:18000/{claude,codex}   Authorization: <サブスクリプションのトークン>、apikey: <Virtual Key>
  ▼
Kong AI Gateway DP（docker、127.0.0.1 のみ）   apikey を Principal に解決して外し、本文の model で Model を選ぶ
  ▼
api.anthropic.com / chatgpt.com（Codex は compose 内の中継を経由）
```

## 必要なもの

- Konnect の org と、AI Gateway を作れる Personal Access Token
- Kong Identity の directory `default` に、自分の Principal があること
- docker、[mise](https://mise.jdx.dev/)、jq、openssl、envsubst（macOS なら `brew install gettext`）
- 使う方の `claude` / `codex`（ログイン済み）

## セットアップ

```bash
git clone <this repo> && cd kong-agent-gateway
mise trust && mise install          # kongctl を固定版で入れる
cp .env.example .env && chmod 600 .env
# .env の PREFIX（例: 自分のユーザー名）と KONNECT_PAT を埋める

mise run principals -- <自分の名前の一部>   # 出てきた ID を .env の PRINCIPAL_ID に書く
mise run doctor
mise run setup                      # 証明書 → Konnect に適用 → Attribution → Virtual Key 発行 → DP 起動
mise run smoke
mise run install                    # claude-kong / codex-kong / kong-up を ~/.local/bin にリンク
```

`mise run setup` は何度実行しても構いません。Konnect には `<PREFIX>-agent-gateway` という AI Gateway が namespace `<PREFIX>-agent-gateway` で作られ、ほかの人のリソースには触れません。

## 使い方

```bash
claude-kong                  # Kong 経由の Claude Code。引数はそのまま claude に渡る
codex-kong -m gpt-6-luna     # Kong 経由の Codex
kong-up stop                 # DP を止める（claude-kong / codex-kong は必要なら自動で起動する）
kong-up logs
```

Claude Code の `/status` で、Anthropic base URL が `http://localhost:18000/claude`、ログイン方法が claude.ai アカウントになっていれば正しく通っています。

- 複数の Claude アカウントを使い分けるときは、`CLAUDE_CONFIG_DIR=~/.claude-other claude-kong` のようにプロファイルを分けます。利用者を分けて集計したいなら、`KONG_VIRTUAL_KEY=... claude-kong` で別の Principal の Virtual Key を渡します。
- Git リポジトリの中で起動すると、リポジトリ名とブランチを Konnect のタグ（`scm-*`）に送ります。送りたくないディレクトリは `.env` の `SCM_TAG_EXCLUDE_DIRS` に書きます。
- Virtual Key を `.env` に置きたくないときは、`KONG_VIRTUAL_KEY` を空にして `KONG_VIRTUAL_KEY_OP_REF="op://..."` を設定します。

## 注意点

- `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN` / `apiKeyHelper` のどれかが有効だと、サブスクリプションではなく API 課金になります。`claude-kong` は環境変数を外しますが、`settings.json` の `apiKeyHelper` は外せません。
- リポジトリの `.claude/settings.json` に `env.ANTHROPIC_CUSTOM_HEADERS` があると、`apikey` を含むヘッダーが丸ごと置き換わり、Kong が 401 を返します。
- `config/kongctl.yaml` に無いモデル ID は 500 になります。新しいモデルを使うときは `config/kongctl.yaml.tmpl` に足して `mise run diff` → `mise run sync` します。sync は宣言から消したリソースを削除します。
- proxy は平文 http で、`127.0.0.1` にだけ公開しています。

## ファイル

| パス | 中身 |
| --- | --- |
| `.env` | 各自の設定と秘密情報（git 管理外）。雛形は `.env.example` |
| `config/kongctl.yaml.tmpl` | Konnect の宣言的設定。`config/kongctl.yaml` はここから生成される（git 管理外） |
| `compose.yaml` | DP と Codex 用の中継。手元だけの変更は `compose.override.yaml`（git 管理外）に書く |
| `codex-upstream/nginx.conf` | ChatGPT のバックエンドへの中継 |
| `bin/` | `claude-kong` / `codex-kong` / `kong-up` |
| `scripts/` | セットアップと確認のスクリプト（`mise run` から呼ぶ） |
| `docs/design-notes.md` | なぜこの構成なのか、実測で分かったこと |
