---
title: "OWASP Juice Shop を apple/container で動かしてみた"
emoji: "📦"
type: "tech"
topics: ["container", "docker", "security", "zap", "cicd"]
published: false
---

## はじめに

apple/container、触ったことがなかったので試してみた。ニュースで見かけて「学習がてら」くらいのノリで始めた話です。この記事は「apple/containerのTipsまとめ」が本題ではなく、Docker前提で組んでいた環境をあえて別基盤に置き換えてみたときに何が起きるか、を実際に手を動かして確認した記録です。

## Dockerでいいじゃん？ダメなの？

最初に断っておくと、Dockerを使うこと自体に不満があったわけではありません。ただ、Docker Desktopには無視できない制約がいくつかあります。

- **有償化**: 2021-08-31に発表。無料利用の条件は「従業員250人未満」**かつ**「年商1000万ドル未満」の両方を満たす場合のみ。どちらか一方でも超えると有償になります（[Docker公式プレスリリース](https://www.docker.com/press-release/docker-updates-product-subscriptions/)、[Docker Desktop license](https://docs.docker.com/subscription/desktop-license/)）
- **現行料金**（2026-07時点）: Personal無料 / Pro $9(年契約)・$11(月契約) / Team $15(年契約)・$16(月契約) / Business $24（[Docker Pricing](https://www.docker.com/pricing/)）
- **Docker Hub pull rate limit**: 匿名ユーザーは6時間で100pull、認証済み無料ユーザーは200pull。Pro以上のプランは無制限（[Docker Hub pull usage and limits](https://docs.docker.com/docker-hub/usage/pulls/)）

「絶対Dockerをやめるべき」という話ではなく、無料で試せる選択肢が他にもあるなら触ってみたい、という程度の温度感でした。

## Dockerの代替候補

軽く調べただけでも候補は複数あります。Podman、Rancher Desktop、OrbStack、colima、そして今回扱うapple/container。それぞれ思想もライセンス体系も違うので、横並びでの比較検証は今回はしていません（気が向いたら別記事にします）。

## 今回はapple/containerを選んだ理由

正直に書くと、深い戦略はありません。

> やったことがない技術で、ニュースで見かけて興味を持った。学習がてら、シンプルに興味本位。

もう一つの実務的な理由は「無料で試せること」。他の候補は業務利用だと有償になるケースがあり、今回はあくまで机上検証なのでコストをかけたくなかった、というのも大きいです。

apple/containerはWWDC25で発表されたApple公式のCLIツールです。公式ドキュメントにはこうあります。

> "it runs a lightweight VM for each container that you create"
> — [apple/container: technical-overview.md](https://github.com/apple/container/blob/main/docs/technical-overview.md)

コンテナごとに軽量VMを1つ立てる設計です。ネットワークもvmnetフレームワーク経由でコンテナごとに個別のIPアドレスが割り当てられます。これは「選んだ理由」というより、触ってみてから知った特徴です。意図的に脆弱なJuice Shopを動かす用途とは相性が良さそうだな、と後から思った程度でした。

## やったこと

環境はApple SiliconのMac（macOS 26.4.1）。[juice-shop-zap-cicd-lab](https://github.com/toxin-don/juice-shop-zap-cicd-lab)というローカル学習用リポジトリで、OWASP ZAPのbaseline scanをDocker環境とapple/container環境の両方で試しています。

使用バージョン: `container` CLI 1.1.0 / ZAPイメージ `ghcr.io/zaproxy/zaproxy:stable` / Juice Shopイメージ `bkimminich/juice-shop`（`org.opencontainers.image.version: 20.1.1`）

### インストールでいきなりつまずいた

```bash
brew install container
```

これ、動きません。`brew`経由だとソースビルドになり、Xcode.app本体が要求されて失敗します。正解はGitHub Releasesから**署名済みpkgインストーラ**を落とすルートでした。

```bash
# container-1.1.0-installer-signed.pkg をGitHub Releasesから取得後
sudo installer -pkg container-1.1.0-installer-signed.pkg -target /
```

初回起動も一癖あります。

```bash
container system start --enable-kernel-install
```

このフラグを付けないと、kernelインストールの対話プロンプトで止まります。

### Juice Shopを起動

composeに相当する機能はまだありませんが、Docker Hubのイメージはそのまま起動できました（OCI互換）。

```bash
container run -d --name juice-shop-native -p 3001:3000 bkimminich/juice-shop
```

```bash
container list
# NAME               IMAGE                       OS     ARCH   STATE    ADDR
# juice-shop-native  docker.io/bkimminich/...    linux  arm64  running  192.168.64.3
```

コンテナごとに個別のIPアドレスが割り当てられます。ZAPからはこのIPを直接指定してアクセスしました。

### ZAP baseline scanを実行

```bash
docker compose run --rm zap zap-baseline.py \
  -t http://192.168.64.3:3000 \
  -r report.html -J report.json -w report.md
```

結果: `FAIL-NEW:0, WARN-NEW:8, PASS:59`

## 結果: Docker環境と同じ検出結果

Docker composeでの通常運用と、apple/container環境（今回）を比較すると、両方とも`FAIL-NEW:0, WARN-NEW:8, PASS:59`で完全に一致しました。検出内容自体はJuice Shop側に依存する話なので、コンテナ基盤を変えても差が出ないのは当然と言えば当然ですが、実際に手を動かして確認できたのは収穫でした。

## 実務で使うなら気をつけること

ここが今回のヤマ場です。composeが無い代わりに個別IPで疎通させましたが、これを自動化に組み込もうとすると壁にぶつかります。

**コンテナを再作成するたびにIPアドレスが変わります。** 実際に`stop`→`rm`→`run`を繰り返して確認したところ、`.3`→`.5`→`.6`と変化しました。

```bash
container stop juice-shop-native && container rm juice-shop-native
container run -d --name juice-shop-native -p 3001:3000 bkimminich/juice-shop
container list
# ADDR: 192.168.64.5  ← 変わった
```

名前解決の手段として`container system dns create`（ローカルDNS）や`container network create`（名前付きネットワーク）も試しましたが、今回の検証範囲ではどちらも機能せず、解決には至りませんでした。

自動化するなら、IPをハードコードするのは危険です。毎回`container list`や`container inspect`で最新のIPを問い合わせるステップが必須になります（最悪の場合、コンテナ再作成で別コンテナが同じIPを引き継いで誤爆する可能性もあります）。

## なぜそもそもDASTを自動化するのか

ここまではapple/containerの検証記録ですが、一歩引くと「なぜこんな面倒なことをしてまでDAST（動的アプリケーションセキュリティテスト）を自動化・ローカル化したいのか」という話になります。

DASTの代表格はOWASP ZAP（無料・OSS）とBurp Suite（商用）です。役割は違っていて、Burpは手動ペンテスト、ZAPはCI/CD自動化に強いとされています。価格感としてもBurp Suite Professionalが$449/年/ユーザー、CI/CD向けのBurp Suite Enterpriseは$17,000+/年、対してZAPは$0〜という開きがあります（[Decryption Digest: Burp Suite vs OWASP ZAP 2026](https://www.decryptiondigest.com/blog/burp-suite-vs-owasp-zap-comparison)より）。

業界動向としては、BSIMM16（111社・開発者約223,700名を対象にした年次調査）でも、SAST自動化（観測率85.6%）・外部pentest（同85.6%）は既に基礎活動として定着している一方、QA自動化へのセキュリティテスト吸収（観測率27.0%）はまだ先進側の取り組みという位置づけでした（[BSIMM16 Report 2026](https://www.blackduck.com/content/dam/black-duck/en-us/reports/bsimm-report.pdf)）。手動でのDASTには限界があり、自動化の波はもう来ています。

とはいえ「自作(OSS)かSaaSか」の二択で悩む必要もないと思っていて、今回みたいに自分の手元で無料のツールを組み合わせて動かしてみる、という選択肢があること自体を確かめたかった、というのが正直なところです。

この記事で一番持ち帰ってほしいのは、apple/containerのTipsそのものよりも「問題があって、理想があって、そのギャップを埋めるためのソリューションがあって、選択肢があって、今回はapple/containerを選んだ」という一連の流れそのものです。Dockerに限らず、何かのツールを検討するときの型として、そのまま使えると思います。

## まとめ

- apple/containerはWWDC25発表のApple公式ツール。コンテナごとに軽量VMを立てる設計で、composeに相当する機能はまだない
- Docker Hubのイメージはそのまま起動できる（OCI互換）。ZAP baseline scanもDocker環境と同じ結果が得られた
- 実務投入するなら「IPが再作成のたびに変わる」制約への対処が必須
- 今回のハンズオンの元ネタ・検証コードは[juice-shop-zap-cicd-lab](https://github.com/toxin-don/juice-shop-zap-cicd-lab)に置いてある

## 参考

- [apple/container](https://github.com/apple/container)
- [apple/container: technical-overview.md](https://github.com/apple/container/blob/main/docs/technical-overview.md)
- [Docker公式プレスリリース: 有償化発表](https://www.docker.com/press-release/docker-updates-product-subscriptions/)
- [Docker Desktop license](https://docs.docker.com/subscription/desktop-license/)
- [Docker Pricing](https://www.docker.com/pricing/)
- [Docker Hub pull usage and limits](https://docs.docker.com/docker-hub/usage/pulls/)
- [OWASP ZAP](https://www.zaproxy.org/)
- [OWASP Juice Shop](https://github.com/juice-shop/juice-shop)
- [Decryption Digest: Burp Suite vs OWASP ZAP 2026](https://www.decryptiondigest.com/blog/burp-suite-vs-owasp-zap-comparison)
- [BSIMM16 Report 2026](https://www.blackduck.com/content/dam/black-duck/en-us/reports/bsimm-report.pdf)
