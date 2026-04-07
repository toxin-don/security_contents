---
title: "GlassWorm攻撃の不可視コードをOpenGrepで検出する"
emoji: "🔍"
type: "tech"
topics: ["security", "opengrep", "sast", "unicode", "supplychainattack"]
published: false
---

## はじめに

2026年3月、不可視属性を持つUnicode文字を悪用した新型サプライチェーン攻撃「GlassWorm」が急増しています。GitHubで151件以上のリポジトリが汚染され、npm・VS Code拡張を含む433件以上のプロジェクトに被害が広がりました。

https://xtech.nikkei.com/atcl/nxt/column/18/00989/040100204/

この攻撃の厄介な点は、**既存のSASTツールやコードレビューでは検出が難しい**こと。異体字セレクター（U+FE00〜U+FE0F）などの表示幅ゼロの文字に18,000行ものコードを隠蔽した事例も報告されています。

本記事では、OSSの静的解析ツール**OpenGrep**（旧Semgrep）のカスタムルールで、GlassWorm攻撃に使われる不可視Unicode文字を検出する方法を紹介します。

## GlassWorm攻撃の仕組み

### 攻撃に使われるUnicode文字

| 文字種 | コードポイント | 用途 | 危険度 |
|--------|-------------|------|--------|
| 異体字セレクター | U+FE00〜U+FE0F | GlassWorm本体。不可視コード隠蔽 | **最高** |
| ゼロ幅文字 | U+200B〜U+200F | ゼロ幅スペース・結合子。コード隠蔽 | **高** |
| 双方向制御文字 | U+202A〜U+202E | Trojan Source攻撃。表示順序の改ざん | **高** |
| BOM/ワードジョイナー | U+FEFF, U+2060〜2064 | 不可視演算子。コード構造の隠蔽 | **中** |

### なぜSASTで検出できないのか

一般的なSASTツールは、ソースコードの**構文パターン**（SQLインジェクション、XSS等）や**データフロー**を解析します。しかし、不可視Unicode文字は:

1. コードエディタやGitHubのレビュー画面で**表示されない**
2. 多くのパーサーが**無視またはスキップ**する
3. SASTの検査対象として**認識されない**

つまり、通常のSASTのスキャン対象の外側にある脅威です。

### リポジトリへの流入経路

```
経路①: 依存パッケージ経由（最もリスク高）
  汚染されたgem/npmパッケージ → bundle install / npm install → 自社リポジトリ

経路②: コピペ経由
  StackOverflow / ChatGPT / GitHub → 不可視文字を含むコードをコピー → コードレビューで見えない
  ※ リポジトリにpushできるのは開発者だけとは限らない（マーケ、デザイナー等も）
  → 非エンジニアのほうがコピペ時のリスク意識が低い可能性がある

経路③: LLM生成コード経由
  攻撃者がLLMで「もっともらしいPR」を大量生成 → OSSが汚染 → 経路①に合流
```

## OpenGrepカスタムルールで検出する

### ルール定義

```yaml
rules:
  - id: invisible-unicode-variant-selectors
    pattern-regex: "[\uFE00-\uFE0F]"
    message: >
      異体字セレクター（Variant Selector: U+FE00〜U+FE0F）が検出されました。
      GlassWorm攻撃では、この文字種を悪用して不可視のコードを埋め込みます。
      ソースコード内に異体字セレクターが存在する正当な理由は通常ありません。
    languages: [generic]
    severity: ERROR
    metadata:
      category: security
      subcategory: [audit]
      confidence: HIGH
      impact: HIGH

  - id: invisible-unicode-zero-width
    pattern-regex: "[\u200B-\u200F]"
    message: >
      ゼロ幅文字（Zero-Width Character: U+200B〜U+200F）が検出されました。
      ソースコード内にこれらの文字が含まれている場合、不可視コードの混入が疑われます。
    languages: [generic]
    severity: WARNING
    metadata:
      category: security
      confidence: HIGH
      impact: HIGH

  - id: invisible-unicode-bidi-control
    pattern-regex: "[\u202A-\u202E\u2066-\u2069]"
    message: >
      双方向制御文字（Bidirectional Control Character）が検出されました。
      Trojan Source攻撃（CVE-2021-42574）で使われる手法です。
    languages: [generic]
    severity: ERROR
    metadata:
      category: security
      cwe: ["CWE-1007"]
      references: ["https://trojansource.codes/"]
      confidence: HIGH
      impact: HIGH

  - id: invisible-unicode-misc
    pattern-regex: "[\u00AD\u2060-\u2064\uFEFF]"
    message: >
      その他の不可視Unicode文字が検出されました。
      ファイル先頭のBOM（U+FEFF）以外で検出された場合は要調査。
    languages: [generic]
    severity: WARNING
    metadata:
      category: security
      confidence: MEDIUM
      impact: MEDIUM
```

### ルールの設計意図

4つのルールに分けたのは、**文字種ごとに脅威レベルが異なる**ため:

- `variant-selectors`: GlassWorm攻撃の本体。ソースコードに存在する正当な理由がほぼない → **ERROR**
- `zero-width`: 攻撃にも使われるが、一部の国際化対応で正当に使われるケースもある → **WARNING**
- `bidi-control`: Trojan Source攻撃（CVE-2021-42574）。既知の攻撃手法 → **ERROR**
- `misc`: BOMなど、ファイル先頭では正当な場合がある → **WARNING**

### 実行方法

```bash
# 単一リポジトリに対して実行
opengrep scan --config glassworm-rules.yml /path/to/repo

# 複数リポジトリに対して日次実行（cronやCI/CDで）
for repo in /path/to/repos/*; do
  opengrep scan --config glassworm-rules.yml "$repo"
done
```

## 検出の限界

このルールで検出**できること**と**できないこと**を明確にしておきます。

### 検出できる

- 自社リポジトリのソースコード内の不可視文字
- デフォルトブランチへの混入（日次スキャンで検知）

### 検出できない

- **依存パッケージ内の不可視文字**（`vendor/`や`node_modules/`を対象に含めない場合）
- **ビルド時に動的に生成されるコード**
- **不可視文字以外の難読化手法**（Base64エンコード、文字列連結等）

依存パッケージまでカバーするには、`bundle install`後の`vendor/`ディレクトリや`node_modules/`もスキャン対象に含める必要があります。ただし、スキャン時間とのトレードオフになります。

## GHASとの比較

GitHub Advanced Security（GHAS）は2026年4月時点で、GlassWorm攻撃に対する専用の検出機能を持っていません。

| 機能 | GlassWorm検出 | 備考 |
|------|:---:|------|
| GHAS Code Scanning (CodeQL) | △ | カスタムクエリで対応可能だが、デフォルトルールにはない |
| GHAS Secret Scanning | × | パターンマッチ対象外 |
| GitHub双方向文字警告 | ○ | Trojan Source対策（2021年追加）。異体字セレクターは対象外 |
| OpenGrepカスタムルール | **○** | 本記事のルールで検出可能 |

## まとめ

- GlassWorm攻撃は**既存のSASTでは検出が難しい**新しい脅威
- OpenGrepのカスタムルールで**不可視Unicode文字を検出**できる
- 4種類の不可視文字を脅威レベル別に分類してルール化
- 依存パッケージまでカバーするにはスキャン対象の拡張が必要
- **検出は第一歩。トリアージと対応プロセスの整備も必要**

## 参考

- [不可視文字でマルウエア混入 — 日経クロステック](https://xtech.nikkei.com/atcl/nxt/column/18/00989/040100204/)
- [Trojan Source: Invisible Vulnerabilities](https://trojansource.codes/)
- [CVE-2021-42574 — Unicode Bidirectional Override](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2021-42574)
- [コピペの前にGeminiで検閲 — Zenn](https://zenn.dev/i_n_dev/articles/2e6b7ee603c673)
- [OpenGrep Documentation](https://opengrep.dev/)
