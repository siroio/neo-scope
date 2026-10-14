# 任意連携の検証

2026-10-14、Windows / Emacs 31.1。ユーザー設定は読み込まず `-Q` で実行し、fixtureと一時ファイルは `neo-scope/build/` 内に限定する。兄弟リポジトリのパッケージは読み取りだけに使用する。

検証したバージョンはConsult 20261004.957、Orderless 20260927.2344、Vertico 20260913.1525。

結果: 全44件のERT成功、バイトコンパイル警告なし、連携GUI成功、0.3.0の隔離インストール・autoload・任意パッケージ未読込の確認成功。

```powershell
emacs -Q --batch -L . -L ../emacs.d/elpa/consult-20261004.957 -L ../emacs.d/elpa/orderless-20260927.2344 -L ../emacs.d/elpa/vertico-20260913.1525 -l neo-scope.el --eval '(setq temporary-file-directory (expand-file-name "build/tmp"))' -l tests/neo-scope-tests.el -l tests/neo-scope-media-tests.el -l tests/neo-scope-media-integration.el -l tests/neo-scope-integration-tests.el -f ert-run-tests-batch-and-exit
```

任意連携のERTは実パッケージによる複数語・日本語照合、一致箇所、実rgの正規表現結果・日本語ファイル名・行番号・Git除外・一致なし・候補上限・中止を確認する。未導入時のフォールバック、収集のtimeout/error時の中止、同名候補とVertico有効状態の復元も検証する。

`tests/neo-scope-integrations-gui.el` は独立Emacsに `-Q -l` で読み込む。neo-scope画面でのOrderlessとConsult結果表示、および実際のVerticoミニバッファでRET確定・C-g取消・モード復元を確認し、自身のEmacsを終了する。

Consultは内部の `consult--ripgrep-make-builder` と `consult--async-process`、raw grep出力のregexpを使う。ミニバッファ専用処理と `setup` によるグローバル読込サイズ変更は呼ばない。プロセス出力はUTF-8として扱う。互換性は上記バージョンで検証し、将来の内部API変更と他OSは未検証。

ユーザー実設定のEvil・IME操作は未検証。
