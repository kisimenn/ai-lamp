#!/bin/bash
# AI通知ランプ まとめて設定（Mac）
#   Claude Code / Codex に「この setup.sh を実行して」と頼めば、次をまとめて行う。
#     1. プラグイン一式を ~/.cache/ai-lamp/market にコピー（展開したフォルダを消しても困らないように）
#     2. Claude Code にプラグインを入れる（入っていれば入れ直す）
#     3. Codex が入っていれば、Codex 用のフックも入れる
#   何度実行しても同じ結果になる。外すときは uninstall.sh
#   ※ 既読で消える機能は、Mac 版にはまだありません
#
#   実行例: bash setup.sh        （Codex の設定を飛ばしたいとき: bash setup.sh --no-codex）
HERE="$(cd "$(dirname "$0")" && pwd)"
MARKET="$HOME/.cache/ai-lamp/market"
SCRIPTS="$MARKET/plugins/ai-lamp-mac/scripts"
GITHUB_REPO="kisimenn/ai-lamp"   # 配布リポジトリ（公開前に書き換える）
NO_CODEX=0
for a in "$@"; do [ "$a" = "--no-codex" ] && NO_CODEX=1; done

if [ "$(uname)" != "Darwin" ] && [ -z "$AI_LAMP_SKIP_OS_CHECK" ]; then
  echo "これは Mac 用の設定です。Windows の方は setup.ps1 を使ってください。"
  exit 1
fi
if [ ! -f "$HERE/.claude-plugin/marketplace.json" ]; then
  echo ".claude-plugin フォルダが見つかりません。ダウンロードして展開したフォルダの中で実行してください: $HERE"
  exit 1
fi

# Claude Code のコマンドを探す（デスクトップアプリ同梱の新しいもの → よくある置き場所 → PATH の順）
# ※ デスクトップアプリ同梱の置き場所は Windows 版を参考にした推測（Mac での確認はまだ）
find_claude() {
  local c f
  c=""
  while IFS= read -r -d "" f; do
    if [ -z "$c" ] || [ "$f" -nt "$c" ]; then c="$f"; fi   # いちばん新しいもの
  done < <(find "$HOME/Library/Application Support/Claude/claude-code" -maxdepth 3 -type f -name claude -print0 2>/dev/null)
  if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return; fi
  for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
    if [ -x "$c" ]; then echo "$c"; return; fi
  done
  command -v claude 2>/dev/null
}

RESULTS=""
DID_CLAUDE=0
DID_CODEX=0
add() { RESULTS="${RESULTS}$1
"; }

# 1. プラグイン一式をコピー
rm -rf "$MARKET"
mkdir -p "$MARKET"
cp -R "$HERE/plugins" "$HERE/.claude-plugin" "$MARKET/"
chmod +x "$SCRIPTS"/*.pl 2>/dev/null
add "OK プラグイン一式をコピーしました: $MARKET"

# 2. Claude Code にプラグインを入れる（いったん外して入れ直す＝何度実行しても同じ）
CLAUDE="$(find_claude)"
if [ -n "$CLAUDE" ]; then
  "$CLAUDE" plugin uninstall ai-lamp@ai-lamp-market >/dev/null 2>&1   # 0.6.6 までの名前（Mac 版も ai-lamp だった）
  "$CLAUDE" plugin marketplace remove ai-lamp-market >/dev/null 2>&1
  # GitHub から入れる（更新が届く）。届かないときはコピーから入れる（更新は届かない）
  FROM="GitHub"; S1=1; R1=""
  case "$GITHUB_REPO" in *OWNER*) ;; *) R1="$("$CLAUDE" plugin marketplace add "$GITHUB_REPO" 2>&1)"; S1=$? ;; esac
  if [ $S1 -ne 0 ]; then
    FROM="このパソコンのコピー"
    "$CLAUDE" plugin marketplace remove ai-lamp-market >/dev/null 2>&1
    R1="$("$CLAUDE" plugin marketplace add "$MARKET" 2>&1)"; S1=$?
  fi
  R2="$("$CLAUDE" plugin install ai-lamp-mac@ai-lamp-market 2>&1)"; S2=$?
  if [ $S1 -eq 0 ] && [ $S2 -eq 0 ]; then
    add "OK Claude Code にプラグインを入れました（入れ元: $FROM。Claude を開き直すと有効になります）"
    DID_CLAUDE=1
  else
    add "NG Claude Code へのプラグインの追加に失敗しました:
$R1
$R2"
  fi
else
  add "-- Claude Code が見つからないので、Claude 用の設定は飛ばしました"
fi

# 3. Codex
if [ $NO_CODEX -eq 0 ] && [ -d "$HOME/.codex" ]; then
  if /usr/bin/perl "$SCRIPTS/codex-install.pl" >/dev/null 2>&1; then
    add "OK Codex 用のフックを入れました（ランプのフックを承認してください。Codex アプリは、入力欄の下に出る、黄色い点付きのフックのアイコン →「フックの確認」で、lamp.pl と書かれたランプ用のフックを許可（全部ランプ用なら「すべて許可」、ほかのフックもあればランプ用だけ選んで「選択した項目を許可」）。これで完了で、設定画面でもう一度同じ操作をする必要はありません。アイコンが無いときは承認済みのこともあるので 設定 → Hooks で確かめます。ターミナルの Codex は /hooks）"
    DID_CODEX=1
  else
    add "NG Codex 用のフックの追加に失敗しました"
  fi
elif [ $NO_CODEX -eq 0 ]; then
  add "-- Codex は入っていないようなので、Codex 用の設定は飛ばしました"
fi

# 4. ランプがつながっているか確かめて、緑に 2 秒光らせる（AI もお客さんも、結果をそのまま見ればよい）
add "$(/usr/bin/perl "$SCRIPTS/lamp.pl" test 2>&1)"

echo "=== AI通知ランプの設定結果 ==="
printf '%s' "$RESULTS"
# 最後の案内は、実際に設定したアプリだけを対象にする
APPS=""
[ $DID_CLAUDE -eq 1 ] && APPS="Claude"
[ $DID_CODEX -eq 1 ] && APPS="${APPS:+$APPS と }Codex"
if [ -n "$APPS" ]; then
  echo "最後に、$APPS のアプリを終了して、開き直してください（Command + Q で終了できます）。"
  if [ $DID_CODEX -eq 1 ]; then
    echo "  ・開き直したら、まだ承認していなければランプのフックを承認します（承認済みなら不要）。"
  fi
  echo "  ・そのあと新しい会話で作業を頼み、青 → 緑 と光るか確かめてください（上の緑 2 秒は「ランプが見つかった」確認で、AI との連動はこれから確かめます）。"
fi
