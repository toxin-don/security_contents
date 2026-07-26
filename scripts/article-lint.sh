#!/bin/bash
# 記事lint: textlint（文言） + 分量メトリクス（決定論的な上限チェック）
# 使い方: ./scripts/article-lint.sh articles/xxx.md
set -u
FILE="$1"
FAIL=0

echo "=== 文言チェック (textlint) ==="
if ! npx textlint "$FILE"; then
  FAIL=1
fi

echo ""
echo "=== 分量チェック ==="
python3 - "$FILE" << 'EOF'
import re, sys
path = sys.argv[1]
text = open(path).read()

# frontmatterを除去
body = re.sub(r'^---\n.*?\n---\n', '', text, count=1, flags=re.S)
# コードブロックを分離
code_blocks = re.findall(r'```.*?```', body, flags=re.S)
prose = re.sub(r'```.*?```', '', body, flags=re.S)
# 表の行を分離
table_lines = [l for l in prose.splitlines() if l.strip().startswith('|')]
prose_only = '\n'.join(l for l in prose.splitlines() if not l.strip().startswith('|'))

chars = len(re.sub(r'\s', '', prose_only))
tables = len([l for l in table_lines if re.match(r'^\|[\s:|-]+\|$', l.strip())])
codes = len(code_blocks)
h2 = len(re.findall(r'^## ', body, flags=re.M))

# 上限（drafts/zenn/記事規約.md と同期）
LIMITS = {'本文文字数(空白・表・コード除く)': (chars, 2500),
          '表': (tables, 2),
          'コードブロック': (codes, 3),
          'H2見出し': (h2, 7)}

fail = False
for name, (val, limit) in LIMITS.items():
    mark = 'OK' if val <= limit else 'OVER'
    if val > limit: fail = True
    print(f'  {name}: {val} / 上限{limit} … {mark}')

sys.exit(1 if fail else 0)
EOF
if [ $? -ne 0 ]; then
  FAIL=1
fi

echo ""
if [ $FAIL -ne 0 ]; then
  echo "RESULT: FAIL（上のOVER/エラーを解消してから公開工程へ）"
  exit 1
fi
echo "RESULT: PASS"
