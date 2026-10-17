#!/bin/bash
# AI通知ランプ まとめて設定（Mac）
#   Claude Code / Codex に「この setup.sh を実行して」と頼めば、次をまとめて行う。
#     1. プラグイン一式を ~/.cache/ai-lamp/market にコピー（展開したフォルダを消しても困らないように）
#     2. Claude Code にプラグインを入れる（入っていれば入れ直す）
#     3. Codex が入っていれば、Codex 用のフックも入れる
#     4. 既読で消える機能（--watch のとき入れる、--no-watch のとき外す。どちらも無ければ今のまま）※Mac 版は試験中
#   何度実行しても同じ結果になる。外すときは uninstall.sh
#
#   実行例: bash setup.sh --watch
#   使わない AI は飛ばせる: --no-claude（Claude Code に入れない）、--no-codex（Codex に入れない）
HERE="$(cd "$(dirname "$0")" && pwd)"
MARKET="$HOME/.cache/ai-lamp/market"
SCRIPTS="$MARKET/plugins/ai-lamp-mac/scripts"
GITHUB_REPO="kisimenn/ai-lamp"   # 配布リポジトリ（公開前に書き換える）
NO_CODEX=0
NO_CLAUDE=0
WATCH=keep
for a in "$@"; do
  [ "$a" = "--no-codex" ] && NO_CODEX=1
  [ "$a" = "--no-claude" ] && NO_CLAUDE=1
  [ "$a" = "--watch" ] && WATCH=on
  [ "$a" = "--no-watch" ] && WATCH=off
done

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
CLAUDE=""
[ $NO_CLAUDE -eq 0 ] && CLAUDE="$(find_claude)"
if [ $NO_CLAUDE -eq 1 ]; then
  add "-- Claude Code では使わないとのことなので、Claude 用の設定は飛ばしました"
elif [ -n "$CLAUDE" ]; then
  "$CLAUDE" plugin uninstall ai-lamp@ai-lamp-market >/dev/null 2>&1   # 0.6.6 までの名前（Mac 版も ai-lamp だった）
  "$CLAUDE" plugin marketplace remove ai-lamp-market >/dev/null 2>&1
  # GitHub から入れる（更新が届く）。届かないときはコピーから入れる（更新は届かない）
  FROM="GitHub"; S1=1; R1=""
  # GitHub から入れるには git が要る。Mac は git が無いと「コマンドラインデベロッパツールを
  # インストールしますか？」という画面が急に出てお客さんが迷うので、git が使えるときだけ GitHub を使う
  HAS_GIT=0
  if xcode-select -p >/dev/null 2>&1; then HAS_GIT=1
  elif command -v git >/dev/null 2>&1 && [ "$(command -v git)" != "/usr/bin/git" ]; then HAS_GIT=1; fi
  if [ $HAS_GIT -eq 1 ]; then
    case "$GITHUB_REPO" in *OWNER*) ;; *) R1="$("$CLAUDE" plugin marketplace add "$GITHUB_REPO" 2>&1)"; S1=$? ;; esac
  fi
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
else
  add "-- Codex では使わないとのことなので、Codex 用の設定は飛ばしました"
fi

# 4. 既読で消える機能（Mac 版は試験中）
WATCH_PLIST="$HOME/Library/LaunchAgents/local.ai-lamp.watch.plist"
if [ "$WATCH" = "keep" ] && [ -f "$WATCH_PLIST" ]; then WATCH=on; fi   # 前に入れていれば、入れ直す（置き場所が変わっても動くように）
if [ "$WATCH" = "on" ]; then
  rm -f "$HOME/.cache/ai-lamp/seen-off"
  add "$(/usr/bin/perl "$SCRIPTS/watch-install.pl" 2>&1)"
elif [ "$WATCH" = "off" ]; then
  /usr/bin/perl "$SCRIPTS/watch-install.pl" --uninstall >/dev/null 2>&1
  add "-- 既読で消える機能は使いません（ランプは、ランプの先のタッチに触れると消えます）"
else
  add "-- 既読で消える機能は入れていません"
fi

# 5. ランプがつながっているか確かめて、緑に 2 秒光らせる（AI もお客さんも、結果をそのまま見ればよい）
add "$(/usr/bin/perl "$SCRIPTS/lamp.pl" test 2>&1)"

echo "=== AI通知ランプの設定結果 ==="
printf '%s' "$RESULTS"
# 最後の案内は、実際に設定したアプリだけを対象にする
APPS=""
[ $DID_CLAUDE -eq 1 ] && APPS="Claude"
[ $DID_CODEX -eq 1 ] && APPS="${APPS:+$APPS と }Codex"
if [ -n "$APPS" ]; then
  echo "（AI へ）ここから先は README の 3 からのとおりに案内してください（画像と操作の説明は一緒に出し、返事を待つのは操作が終わったときだけ）。下の案内を一度にまとめて伝えないでください。"
  echo "最後に、$APPS のアプリを終了して、開き直してください（command キーを押したまま Q を押すと終了できます）。"
  if [ $DID_CODEX -eq 1 ]; then
    echo "  ・開き直したら、まだ承認していなければランプのフックを承認します（承認済みなら不要）。"
  fi
  echo "  ・そのあと新しい会話で「こんにちは」と送り、送ったあとに青、返事が終わると緑に光るか確かめてください（上の緑 2 秒は「ランプが見つかった」確認で、AI との連動はこれから確かめます）。"
fi
echo ""
echo "光り方は、AI に頼めば変えられます。たとえば:"
echo "  ・「作業中の色を紫にして」"
echo "  ・「夜は暗くして」"
echo "  ・「作業が終わったら虹色でお祝いして」"
echo "  ・「作業が10分を超えたら色を変えて」"
echo "  ・「やさしい光り方にして」（ほかに 派手・夜用・集中）"
