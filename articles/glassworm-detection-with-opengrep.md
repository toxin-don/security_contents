---
title: "GlassWorm攻撃の不可視コードをOpenGrepで検出する"
emoji: "🔍"
type: "tech"
topics: ["security", "unicode", "supplychainattack", "codereview", "oss"]
published: true
---

## はじめに

2026年3月、不可視属性を持つUnicode文字を悪用した新型サプライチェーン攻撃「GlassWorm」が急増しています。GitHubで151件以上のリポジトリが汚染され、npm・VS Code拡張を含む433件以上のプロジェクトに被害が広がりました。

https://xtech.nikkei.com/atcl/nxt/column/18/00989/040100204/

この攻撃の厄介な点は、**既存のSASTツールやコードレビューでは検出が難しい**こと。異体字セレクター（Variation Selector）などの表示幅ゼロの文字を使い、見た目は1行のコードの中に1万8000行あまりの不可視コードを埋め込んだ事例も報告されています。

本記事では、OSSの静的解析ツール**OpenGrep**（[Semgrep v1.100.0からのフォーク](https://github.com/opengrep/opengrep)）のカスタムルールで、GlassWorm攻撃に使われる不可視Unicode文字を検出する方法を紹介します。

## GlassWorm攻撃の仕組み

### 攻撃に使われるUnicode文字

| 文字種 | コードポイント | 用途 | 危険度 |
|--------|-------------|------|--------|
| 異体字セレクター | U+FE00〜U+FE0F、U+E0100〜U+E01EF | GlassWorm本体。不可視コード隠蔽 | **最高** |
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

実際のGlassWormキャンペーンで最も報告されている経路は、**悪意あるVS Code/Open VSX拡張機能経由**です。2026年3月のWave 5では151のGitHubリポジトリと2つのnpmパッケージが侵害され、2026年1月末以降で72以上の悪性Open VSX拡張機能が確認されています。盗んだnpm/GitHub/OpenVSX/Gitの認証情報を使い、感染した開発者自身が次の感染源になる自己増殖（self-propagating worm）という特徴があります（[The Hacker News](https://thehackernews.com/2026/03/glassworm-supply-chain-attack-abuses-72.html)、[Dark Reading](https://www.darkreading.com/application-security/self-propagating-glassworm-vs-code-supply-chain)）。

自社リポジトリへの二次的な流入経路としては、汚染された依存パッケージ経由（`npm install`等）や、コードレビューで不可視文字が見えないままのコピペ経由も考えられます。

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

### 動作確認

opengrep 1.2.2で、上記4ルールを実際に検証しました。異体字セレクター・ゼロ幅文字・双方向制御文字・BOM/ワードジョイナーをそれぞれ実際に埋め込んだテストファイル4本と、不可視文字を一切含まないクリーンなファイル1本を用意し、スキャンを実行しています。

```
Ran 4 rules on 5 files: 5 findings.

testfiles/bidi_control.js
 ❯❯❱ invisible-unicode-bidi-control
        2┆ // check [U+202E]permission level

testfiles/misc_bom.js
 ❯❱ invisible-unicode-misc
        2┆ const label = "Total:[U+2060] ";
        3┆ const suffix = "USD[U+FEFF]";

testfiles/variant_selector.js
 ❯❯❱ invisible-unicode-variant-selectors
        2┆ // normal comment here[U+FE00]

testfiles/zero_width.js
 ❯❱ invisible-unicode-zero-width
        2┆ const name = user[U+200B].name;
```

※ 実際の出力では不可視文字はそのまま（見えないまま）表示されます。本記事では読者環境への混入を防ぐため、出力中の不可視文字を `[U+XXXX]` の可視表記に置換しています。

4ルール全てが意図通り検出できました。不可視文字を含まないクリーンなファイルでは検出0件で、誤検知（false positive）も確認していません。

## 検出の限界

このルールで検出**できること**と**できないこと**を明確にしておきます。

### 検出できる

- 自社リポジトリのソースコード内の不可視文字（上記の動作確認で実証済み）
- デフォルトブランチへの混入（日次スキャンで検知）

### 検出できない

- **依存パッケージ内の不可視文字**（`vendor/`や`node_modules/`を対象に含めない場合）
- **ビルド時に動的に生成されるコード**
- **不可視文字以外の難読化手法**（Base64エンコード、文字列連結等）
- **異体字セレクターの補助面拡張範囲（U+E0100〜U+E01EF）**。実際のGlassWormはこの240文字分の拡張範囲もペイロードのエンコードに使用していますが（[Endor Labs](https://www.endorlabs.com/reports/invisible-threats-glassworm-unicode-vscode)）、本記事のルールは基本面（U+FE00〜U+FE0F）のみをカバーしており、この拡張範囲は未対応です

依存パッケージまでカバーするには、`bundle install`後の`vendor/`ディレクトリや`node_modules/`もスキャン対象に含める必要があります。ただし、スキャン時間とのトレードオフになります。

## 既存の検出手段との比較

「カスタムルールを書く前に、既存の仕組みで足りないのか」を整理しておきます。

筆者が確認した範囲（2026年7月時点）では、GitHub Advanced Security（GHAS）のデフォルト機能に、異体字セレクターやゼロ幅文字を検出する仕組みは見当たりませんでした。双方向制御文字のみ、Trojan Source対応として[2021年10月からGitHubのWeb UIが警告を表示](https://github.blog/changelog/2021-10-31-warning-about-bidirectional-unicode-text/)します。

Semgrep公式ルールレジストリ（OpenGrepが参照する[opengrep-rules](https://github.com/opengrep/opengrep-rules)はそのフォーク）には、双方向制御文字の検出ルール[`generic/unicode/security/bidi.yml`](https://github.com/semgrep/semgrep-rules/blob/develop/generic/unicode/security/bidi.yml)が既に存在します。ただしconfidence: LOWの汎用警告で、GlassWorm本体が使う異体字セレクターのルールは見当たりませんでした（2026年7月時点、筆者確認）。つまりTrojan Source（双方向制御文字）までは既存ルールでカバーできますが、異体字セレクターはカバーできない — これが本記事でカスタムルールを書いた理由です。

| 手段 | 双方向制御文字 | 異体字セレクター | 備考 |
|------|:---:|:---:|------|
| GHAS Code Scanning (CodeQL) | △ | △ | カスタムクエリで対応可能だが、デフォルトルールにはない |
| GHAS Secret Scanning | × | × | パターンマッチ対象外 |
| GitHub双方向文字警告 | ○ | × | Trojan Source対策（2021年10月〜） |
| Semgrep公式レジストリ | ○ | × | `bidi.yml`（confidence: LOW）。異体字セレクターのルールは無い |
| OpenGrepカスタムルール（本記事） | **○** | **○** | 異体字セレクターは基本面のみ（「検出の限界」参照） |

なお、その他の商用SAST製品（SonarQube、Snyk Code等）については筆者は未検証です。

## まとめ

- OpenGrepのカスタムルールで、実際に不可視Unicode文字を検出できることをopengrep 1.2.2で実証した（4ルール・5findings、誤検知0件）
- ただし基本面（U+FE00〜U+FE0F）のみのカバーで、実際のGlassWormが使う補助面拡張範囲（U+E0100〜U+E01EF）は今回のルールでは未対応。実運用で使うなら拡張が必要
- 実際の主要感染経路はVS Code/Open VSX拡張機能経由。依存パッケージ・コピペは二次的な経路
- 検出は第一歩。トリアージと対応プロセスの整備も必要

## 参考

- [不可視文字でマルウエア混入 — 日経クロステック](https://xtech.nikkei.com/atcl/nxt/column/18/00989/040100204/)
- [Trojan Source: Invisible Vulnerabilities](https://trojansource.codes/)
- [CVE-2021-42574 — Unicode Bidirectional Override](https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2021-42574)
- [コピペの前にGeminiで検閲 — Zenn](https://zenn.dev/i_n_dev/articles/2e6b7ee603c673)
- [OpenGrep Documentation](https://opengrep.dev/)
- [opengrep/opengrep — GitHub（Semgrep v1.100.0からのフォーク）](https://github.com/opengrep/opengrep)
- [semgrep-rules: generic/unicode/security/bidi.yml — 公式レジストリの双方向制御文字検出ルール](https://github.com/semgrep/semgrep-rules/blob/develop/generic/unicode/security/bidi.yml)
- [Warning about bidirectional Unicode text — GitHub Changelog](https://github.blog/changelog/2021-10-31-warning-about-bidirectional-unicode-text/)
