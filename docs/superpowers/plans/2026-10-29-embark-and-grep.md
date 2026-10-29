# Embark引き継ぎと全文検索応答性 Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 絞り込んだEmbark候補をneo-scopeへ渡し、標準全文検索中もEmacsを操作できるようにする。
**Architecture:** 検索は同じEmacs内でファイル内の走査もタイマー分割する。Embarkは公開の候補一括操作・フックを使う任意アダプターに限定する。両方とも既存のsource契約を利用する。
**Tech Stack:** Emacs Lisp、Emacs 29.1以上、任意のEmbark/Consult。
**Spec:** ../specs/2026-10-29-embark-candidates-design.md

## Global Constraints

- 変更はneo-scope内。実環境・emacs.dの変更、commit/push/worktree作成はしない。
- 既存検索条件・未保存バッファ・候補の移動先を保持する。外部依存を必須にしない。
- テストの一時ファイル・生成物はbuild内。実ユーザーinitは読み込まない。
- ユーザーの追加実行指示に従い、このセッションで続行する。記録はSmart Brainを主とし、検証結果をdocsに残す。

## Review Focus

- 検索取消直後に届く候補を表示しない。タイマーと走査バッファが残らない。
- UTF-8/UTF-16/日本語、隠しファイル、結果上限が変更前と一致する。
- 読取失敗や空の検索を適切に終了する。検索用の別プロセスを起動しない。
- 同名・混在候補、編集済みバッファの行・列が別の対象へ変わらない。
- ミニバッファを閉じる順序とneo-scope終了時の画面復元が正しい。

## Task 1: 全文検索を同じEmacs内で分割

**Files:** neo-scope.el、tests/neo-scope-grep-tests.el、tests/neo-scope-grep-benchmark.el、README.md。
**Interfaces:** 既存の `neo-scope--elisp-file-source(root, grep)` とsource契約を維持する。

- [x] 実repoの基準値を取得する。件数・内容ハッシュ・初回結果・完了時間・イベント処理待ちを出力する。
- [x] ファイル内の走査中にも処理を分割するテストを追加し、現状で失敗することを確認する。
- [x] 行の走査状態を保持し、空入力・読取失敗・取消・同一プロセス内実行を扱う。
- [x] 文字コード・除外・上限・キャンセルのテスト、既存テストを実行する。結果は全件PASS。
- [x] 同じ実repo条件で再測定し、処理時間と応答性を分けて記録する。

## Task 2: Embark候補の引き継ぎ

**Files:** neo-scope-embark.el、tests/neo-scope-embark-tests.el、tests/neo-scope-embark-gui.el、README.md。
**Interfaces:** `neo-scope-embark(candidates)` をEmbarkの一括アクションとして登録する。フックから型を取得し、既存sourceへ変換する。`neo-scope-embark-setup()` を明示的な登録口にする。

- [x] 実Embarkの一括操作と候補変換のテストを追加し、機能不足で失敗することを確認する。
- [x] file/buffer/consult-location/consult-grep/multi-categoryを扱う最小の任意連携を実装する。
- [x] 空・対応外・消えた対象・同名・未保存・位置保持と、標準exportを変更しないことを検証する。
- [x] 専用GUIでConsultから一括引き継ぎ→絞り込み→プレビュー→確定/取消を検証する。

## Final Verification

- [x] 関連ERT全体、バイトコンパイル、必要なGUI回帰を確認する。
- [x] 全差分を新しいレビュー担当に読み取りで確認してもらい、実害のある指摘を修正・再検証する。
- [x] git diff --check、対象絶対パスの再読込、最終git statusを確認し、検証結果と限界を報告する。

## 判断と記録

- Ruling: ユーザー指定に従い別プロセス案を撤去し、同じEmacs内のタイマー分割へ変更。同期I/O自体の待ち時間は残る。
- 実行記録はSmart Brain、検証ログはbuild/embark-grepに置く。commitと作業ディレクトリ削除は行わない。
- Task 1: 完了。分割・取消の赤テストを確認後、同一Emacs内の実装で成功。実repoと高密度fixtureは全候補ハッシュ一致。数値はdocs/embark-grep-verification.md。
- Task 2: 完了。実Embark一括操作・Collect・Consultの実候補で検証。実GUIで入力フォーカスの問題を再現し、Embark終了後に開く変更で15項目成功。
- Final: fixed Consult混在候補のバッファオブジェクト拒否 — neo-scope-embark-real-consult-mixed-buffer-objects RED→GREEN、全ERT 67/67・GUI 15項目成功。
- Final: Ruling: レビュー担当が未判定とした物理キー入力時の体感速度と遅いドライブは未検証として明示する。測定はイベント処理待ち、GUIはキー列による自動操作に限定し、実環境での待ち時間を保証しない。
