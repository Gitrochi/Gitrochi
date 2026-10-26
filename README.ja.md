<p align="center">
  <img src="docs/images/icon.png" width="112" alt="Gitrochi アイコン">
</p>

<h1 align="center">Gitrochi</h1>

<p align="center">
  <b>履歴をグラフで見て、クリックで操作する Git クライアント。</b><br>
  macOS · Windows
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · 日本語
</p>

<p align="center">
  <a href="https://github.com/Gitrochi/Gitrochi/releases/latest"><img src="https://img.shields.io/github/v/release/Gitrochi/Gitrochi?label=%E6%9C%80%E6%96%B0%E7%89%88&color=2f6fec" alt="最新版"></a>
  <a href="https://github.com/Gitrochi/Gitrochi/releases"><img src="https://img.shields.io/github/downloads/Gitrochi/Gitrochi/total?label=%E3%83%80%E3%82%A6%E3%83%B3%E3%83%AD%E3%83%BC%E3%83%89&color=2a9a55" alt="ダウンロード"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-111?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Windows-10%20%C2%B7%2011-0078d4?logo=windows&logoColor=white" alt="Windows 10 · 11">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT%20%7C%20Community%20Use%20v1.0%20proposed-6b6b72" alt="MIT; Community Use v1.0 proposed"></a>
</p>

<p align="center">
  <a href="https://github.com/Gitrochi/Gitrochi/releases/latest"><b>⬇&nbsp; ダウンロード</b></a>
  &nbsp;·&nbsp; <a href="docs/features.md">使い方と機能（英語）</a>
  &nbsp;·&nbsp; <a href="CONTRIBUTING.md">コントリビュート（英語）</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
    <img src="docs/images/hero-light.png" alt="Gitrochi のメイン画面 — 左にブランチとタグ、中央にコミットグラフ、右に未コミットの変更とコミット入力">
  </picture>
</p>

Gitrochi は macOS と Windows 向けのネイティブ Git クライアントです。履歴を読みやすいコミットグラフに描き、ステージ・コミット・ブランチ・マージ・レビューをクリックで行えます。GitHub と GitLab、CI/CD、AI が書くコミットメッセージ、コーディングエージェント、ターミナルがアプリに組み込まれています。作業は Git 自身が行います。Gitrochi はシステムの `git` を呼び出します。

## 機能

- **コミットグラフ** — すべてのブランチをレーン色で描き、ブランチとタグは専用の列に。作者のプロフィール画像と CI の状態、各ワークツリーの未コミットの変更を最上部に表示
- **ステージとコミット** — ファイル・ハンク・行単位。統合表示と左右表示の diff（単語単位の強調、画像の比較）、コンフリクト解決、コミットの整理（squash・並べ替え・メッセージ修正）、直前の操作の取り消し
- **ドラッグ＆ドロップでブランチ操作** — ブランチをコミットに落とすとマージ・リベース・fast-forward、コミットをブランチに落とすと cherry-pick
- **GitHub と GitLab** — PR/MR のレビュー・承認・作成をアプリ内で（Markdown 対応）。セルフホストの GitLab にも対応
- **CI/CD** — GitLab パイプラインと GitHub Actions：手動ジョブの実行、再実行、キャンセル、デプロイの承認、ワークフローの起動
- **AI** — Claude Code・Codex・Gemini CLI または API キーが、チームのルールに沿ってコミットメッセージと PR の文章を書き、変更をテーマごとに分けてコミット
- **コーディングエージェント** — Claude Code・Codex・Gemini CLI のセッションをワークツリーごとに内蔵ターミナルで起動し、状態をサイドバーに表示
- **ターミナル** — グラフの下にリポジトリフォルダのシェルをタブと分割ペインで。git コマンドを打つとグラフがすぐ更新
- **gitch** — 同梱の CLI がリポジトリごとに Git アカウントを固定し、誤った作者・シークレット・force push をフックで防止

使い方とショートカットを含む全機能の一覧：[docs/features.md](docs/features.md)（英語）。

## インストール

**macOS 15 以降**（Apple Silicon・Intel）：[最新リリース](https://github.com/Gitrochi/Gitrochi/releases/latest)から `.dmg` をダウンロードし、`Gitrochi.app` をアプリケーションフォルダへ移動します。まだ公証を受けていないビルドのため、**システム設定 → プライバシーとセキュリティ → このまま開く**で許可するか、`xattr -dr com.apple.quarantine /Applications/Gitrochi.app` を実行してください。`git` が必要です（Xcode または `xcode-select --install`）。

**Windows 10 (1809) 以降、x64**：[最新リリース](https://github.com/Gitrochi/Gitrochi/releases/latest)から `Gitrochi_<バージョン>_x64-setup.exe` をダウンロードして実行します（`_portable.zip` はインストール不要）。SmartScreen に止められたら**詳細情報 → 実行**。[Git for Windows](https://git-scm.com/download/win) が必要です。

どちらのアプリも自動更新します。起動時と 1 日 1 回新しいバージョンを確認し、署名とハッシュが一致したときだけインストールします。

## コントリビュート

- [CONTRIBUTING.md](CONTRIBUTING.md) — はじめ方、ビルド、プルリクエスト
- [docs/code-style.md](docs/code-style.md) · [docs/git-workflow.md](docs/git-workflow.md) — コード・コミット・ブランチのルール
- [AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md) — コーディングエージェント向けの同じルール

ドキュメントは英語で書かれています。

## フィードバック

- 🐞 [バグ報告](https://github.com/Gitrochi/Gitrochi/issues/new?template=bug_report.yml) · ✨ [機能要望](https://github.com/Gitrochi/Gitrochi/issues/new?template=feature_request.yml) · 💬 [質問](https://github.com/Gitrochi/Gitrochi/issues/new?template=question.yml)
- セキュリティの問題は Issue ではなく[非公開で](SECURITY.md)

## ライセンス

[Gitrochi Community Use License v1.0](LICENSE) は**提案段階で、まだ発効していません**。個人・企業の無料利用を認め、無断の再販売や独立した派生プロジェクトの配布を制限し、貢献は公式リポジトリへのプルリクエストで受け付ける内容です。発効に必要な権利者の同意と法的な詳細は[ライセンス移行の検討記録](docs/licensing-review.md)（韓国語）に記録しています。

現在適用される [MIT の原文](LICENSE-MIT)は併せて保存しており、すでに MIT で付与された権利はこの提案によって取り消されません。© 2026 ChoMnSeong, [jjunhaa0211](https://github.com/jjunhaa0211)。採択後も、配布制限のある source-available ポリシーであり、オープンソースライセンスではありません。

同梱：[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT）。Windows 版は [Tauri](https://tauri.app)、[React](https://react.dev)、[xterm.js](https://xtermjs.org)、[portable-pty](https://github.com/wezterm/wezterm)、[Lucide](https://lucide.dev) の上に作られており、それぞれのライセンスに従います。提案ライセンスはこれらサードパーティコードの権利を制限しません — [サードパーティ通知と依存関係レビュー](THIRD_PARTY_NOTICES.md)（英語）。Rust 依存関係の配布対象ごとの完全な通知レビューはまだ完了していません。
