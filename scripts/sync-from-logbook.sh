#!/bin/bash
# sync-from-logbook.sh
# logbook/drafts/zenn/ の記事を articles/ に安全にコピーする
#
# 安全弁:
#   - published: true の記事を検出したら警告して停止
#   - 社内固有情報のNGワードチェック
#
# 使い方:
#   cd ~/security_contents && ./scripts/sync-from-logbook.sh

set -euo pipefail

LOGBOOK_DRAFTS="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/logbook/drafts/zenn"
ARTICLES_DIR="$(cd "$(dirname "$0")/.." && pwd)/articles"

# NGワード（社内固有情報）
NG_WORDS=("GAテクノロジーズ" "GA Technologies" "RENOSY" "リノシー" "renosy")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "=== Zenn記事同期 ==="
echo "Source: $LOGBOOK_DRAFTS"
echo "Dest:   $ARTICLES_DIR"
echo ""

if [ ! -d "$LOGBOOK_DRAFTS" ]; then
  echo -e "${RED}ERROR: ソースディレクトリが見つかりません${NC}"
  exit 1
fi

has_error=0
files_copied=0

for src in "$LOGBOOK_DRAFTS"/*.md; do
  [ -f "$src" ] || continue
  filename=$(basename "$src")
  dest="$ARTICLES_DIR/$filename"

  echo "--- $filename ---"

  # published: true チェック
  if grep -q 'published:[[:space:]]*true' "$src"; then
    echo -e "${RED}BLOCKED: published: true が設定されています${NC}"
    echo "公開設定は Zenn ダッシュボードまたは手動で行ってください"
    has_error=1
    continue
  fi

  # NGワードチェック
  ng_found=0
  for word in "${NG_WORDS[@]}"; do
    if grep -qi "$word" "$src"; then
      echo -e "${RED}BLOCKED: NGワード '$word' が含まれています${NC}"
      ng_found=1
      has_error=1
    fi
  done
  if [ "$ng_found" -eq 1 ]; then
    continue
  fi

  # 差分表示（既存ファイルがある場合）
  if [ -f "$dest" ]; then
    if diff -q "$src" "$dest" > /dev/null 2>&1; then
      echo -e "${GREEN}変更なし${NC}"
      continue
    else
      echo "差分:"
      diff --color=auto "$dest" "$src" || true
    fi
  else
    echo -e "${YELLOW}新規記事${NC}"
  fi

  cp "$src" "$dest"
  echo -e "${GREEN}コピー完了${NC}"
  files_copied=$((files_copied + 1))
done

echo ""
echo "=== 結果 ==="
echo "コピー: ${files_copied}件"
if [ "$has_error" -eq 1 ]; then
  echo -e "${RED}一部の記事がブロックされました。上記のエラーを確認してください${NC}"
  exit 1
fi
echo -e "${GREEN}完了${NC}"
