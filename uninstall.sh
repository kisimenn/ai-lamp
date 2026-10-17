#!/bin/bash
# AI通知ランプ まとめて外す（Mac）
#   Claude Code のプラグイン、Codex のフック、既読で消える機能、ランプの記録をすべて外す。
#   実行例: bash uninstall.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/plugins/ai-lamp-mac/scripts"

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

if [ -f "$HOME/.codex/hooks.json" ]; then
  /usr/bin/perl "$SCRIPTS/codex-uninstall.pl" >/dev/null 2>&1 && echo "OK Codex のフックを外しました"
fi

CLAUDE="$(find_claude)"
if [ -n "$CLAUDE" ]; then
  "$CLAUDE" plugin uninstall ai-lamp-mac@ai-lamp-market >/dev/null 2>&1
  "$CLAUDE" plugin uninstall ai-lamp@ai-lamp-market >/dev/null 2>&1   # 0.6.6 までの名前
  "$CLAUDE" plugin marketplace remove ai-lamp-market >/dev/null 2>&1
  echo "OK Claude Code のプラグインを外しました"
fi

# 既読で消える機能（見張り）を止めて外す
if [ -f "$HOME/Library/LaunchAgents/local.ai-lamp.watch.plist" ]; then
  /usr/bin/perl "$SCRIPTS/watch-install.pl" --uninstall
fi

rm -rf "$HOME/.cache/ai-lamp"
echo "OK ランプの記録を消しました"
echo "Claude（や Codex）のアプリを一度閉じて、開き直すと完全に外れます。"
