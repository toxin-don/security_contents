#!/bin/bash
# 文書lint: textlint（文言） + 密度チェック（表記の癖） + 分量チェック（Zenn記事のみ）
#
# 使い方:
#   ./scripts/article-lint.sh articles/xxx.md                    # プロファイル zenn（既定）
#   ./scripts/article-lint.sh --profile common  ~/logbook/notes/xxx.md
#   ./scripts/article-lint.sh --profile resume  ~/logbook/projects/job-search/書類/職務経歴書-draft.md
#
# プロファイル:
#   zenn   … Zenn記事。分量上限つき（drafts/zenn/記事規約.md と同期）
#   common … ノート・提出フォーム・メール文面・1on1資料
#   resume … 職務経歴書・履歴書。体言止め/コロン/太字を緩和（実績の箇条書きでは正しい書き方のため）
#
# 2026-08-13 Zenn記事専用から全文書対応へ。経緯は
# logbook/notes/decisions/20260813-文書lintの全ドキュメント展開.md
set -u

PROFILE="zenn"
FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    -*) echo "不明なオプション: $1" >&2; exit 2 ;;
    *) FILE="$1"; shift ;;
  esac
done

if [ -z "$FILE" ]; then
  echo "使い方: $0 [--profile zenn|common|resume] <ファイル>" >&2
  exit 2
fi
if [ ! -f "$FILE" ]; then
  echo "ファイルが見つかりません: $FILE" >&2
  exit 2
fi

case "$PROFILE" in
  zenn)   CONFIG=".textlintrc.json" ;;
  common) CONFIG=".textlintrc.common.json" ;;
  resume) CONFIG=".textlintrc.resume.json" ;;
  *) echo "不明なプロファイル: $PROFILE（zenn / common / resume）" >&2; exit 2 ;;
esac

FAIL=0
echo "=== プロファイル: $PROFILE ==="
echo ""

echo "=== 文言チェック (textlint) ==="
if ! npx textlint --config "$CONFIG" "$FILE"; then
  FAIL=1
fi

echo ""
echo "=== 表記・分量チェック ==="
python3 - "$FILE" "$PROFILE" << 'EOF'
import re, sys
path, profile = sys.argv[1], sys.argv[2]
text = open(path).read()

# frontmatterを除去
body = re.sub(r'^---\n.*?\n---\n', '', text, count=1, flags=re.S)
# コードブロックを分離
code_blocks = re.findall(r'```.*?```', body, flags=re.S)
prose = re.sub(r'```.*?```', '', body, flags=re.S)
# 表の行を分離
table_lines = [l for l in prose.splitlines() if l.strip().startswith('|')]
prose_only = '\n'.join(l for l in prose.splitlines() if not l.strip().startswith('|'))

fail = False

def check(name, val, limit, hint='', warn_only=False):
    global fail
    over = val > limit
    if over and not warn_only:
        fail = True
    mark = ('WARN' if warn_only else 'OVER') if over else 'OK'
    suffix = f'  … {hint}' if (over and hint) else ''
    print(f'  {name}: {val} / 上限{limit} … {mark}{suffix}')

# 太字・コロン・体言止めは文書の型によって正解が変わる（フォームの下書きや台帳では
# 構造化されているのが正しい）。読み物である記事だけ FAIL にし、他は警告に留める。
# 2026-08-13 ベイカレント事前確認シート（太字62個/見出し18・コロン45%）で確認。
soft = (profile != 'zenn')

# ---- 分量（Zenn記事のみ。記事規約の値） ----
if profile == 'zenn':
    chars = len(re.sub(r'\s', '', prose_only))
    tables = len([l for l in table_lines if re.match(r'^\|[\s:|-]+\|$', l.strip())])
    h2 = len(re.findall(r'^## ', body, flags=re.M))
    print('[分量]')
    check('本文文字数(空白・表・コード除く)', chars, 2500)
    check('表', tables, 2)
    check('コードブロック', codes := len(code_blocks), 3)
    check('H2見出し', h2, 7)
    print('')

# ---- 表記の癖（2026-08-13 Qiita記事 minorun365 から取り込み） ----
print('[表記]')
lines = prose_only.splitlines()

# 敬体の見出し（全プロファイル）
keitai = [(i + 1, l) for i, l in enumerate(lines)
          if re.match(r'^#{1,6} ', l) and re.search(r'(します|ます|ましょう|でしょう|ください)$', l.strip())]
check('敬体の見出し', len(keitai), 0, '言い切りか体言止めにする')
for ln, l in keitai[:3]:
    print(f'      L{ln}: {l.strip()}')

if profile != 'resume':
    # 太字の密度: 見出し1つあたり3個まで。見出しが無い文書は全体で5個まで
    bold = len(re.findall(r'\*\*[^*\n]+\*\*', prose_only))
    heads = len(re.findall(r'^#{1,6} ', prose_only, flags=re.M))
    if heads > 0:
        check('太字（見出し1つあたり）', round(bold / heads, 1), 3.0, f'太字{bold}個 / 見出し{heads}個', soft)
    else:
        check('太字', bold, 5, '', soft)

    # コロン区切りの行の割合
    body_lines = [l for l in lines if l.strip() and not re.match(r'^#{1,6} ', l)]
    colon = [l for l in body_lines if re.search(r'[：:]\s*\S', l) and not re.search(r'https?://', l)]
    ratio = round(100 * len(colon) / len(body_lines)) if body_lines else 0
    check('コロン区切りの行の割合(%)', ratio, 30, 'かぎかっこや読点でつなぐ', soft)

    # 体言止めの連続（段落行のみ。箇条書き・見出し・表は自然な体言止めなので除外）
    def is_taigen(l):
        s = l.strip()
        if not s or re.match(r'^([-*+]|\d+\.|>|#{1,6} |\|)', s):
            return False
        return bool(re.search(r'[一-龥ァ-ヶーA-Za-z0-9]$', s))
    run = maxrun = 0
    for l in lines:
        run = run + 1 if is_taigen(l) else 0
        maxrun = max(maxrun, run)
    check('体言止めの連続', maxrun, 2, '3行以上続いたら文にする', soft)

sys.exit(1 if fail else 0)
EOF
if [ $? -ne 0 ]; then
  FAIL=1
fi

echo ""
if [ $FAIL -ne 0 ]; then
  echo "RESULT: FAIL（上のOVER/エラーを解消してから公開・提出へ）"
  exit 1
fi
echo "RESULT: PASS"
