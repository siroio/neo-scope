# neo-scope

Emacs標準機能だけで動くFloating Fuzzy Finderです。左に候補一覧と検索欄、右にコードプレビューを子フレームで表示します。Vertico・Consult・Orderless・posframe・外部実行ファイルは実行時に不要です。

GUI Emacs 29.1以降を対象とします。Windows / Emacs 31.1で自動検証しています。他OSと実際のIME入力は未検証です。

## GitHubからのインストール

Emacs 30以降の標準use-packageでGitHubから導入できます。取得にはGitが必要です。

```elisp
(use-package neo-scope
  :vc (:url "https://github.com/siroio/neo-scope" :rev :newest)
  :commands (neo-scope-find-file neo-scope-buffer neo-scope-grep))
```

`:rev :newest` は導入時に最新コミットを選びます。起動のたびに自動更新する指定ではありません。`:commands` によりコマンドを呼ぶまで本体の読み込みを遅延します。

Emacs 29.1では `package-vc-install` を使用できます。手元の本体は `M-x package-install-file` で `neo-scope.el` を選んでインストールできます。開発用の読み込みは次の形です。

```elisp
(add-to-list 'load-path "C:/path/to/neo-scope")
(require 'neo-scope)
```

## コマンドと操作

| コマンド | 用途 |
| --- | --- |
| `neo-scope-find-file` | プロジェクト内のファイル検索。プロジェクト外なら現在のディレクトリ以下 |
| `neo-scope-buffer` | 通常のバッファを切り替え。編集中の内容をプレビュー |
| `neo-scope-grep` | ローカルファイル内のリテラル文字列検索。大文字小文字は区別しない |

ファイル検索・全文検索は `C-u M-x …` でルートを選択できます。

| キー | 操作 |
| --- | --- |
| 文字入力 | 入力欄で検索。ファイル・バッファは部分列のファジーマッチ |
| `C-n` / `C-p`、上下キー | 候補移動 |
| `RET` | 元のウィンドウで開く |
| `C-g` / `Esc` | 閉じて元の編集位置へ戻る |
| `M-p` / `M-n` | 検索履歴 |
| `C-x o` | 各ペインへ移動 |

確定・キャンセル・候補移動は全ペインで使用できます。プレビューは独立した読み取り専用バッファを使い、元のバッファや未保存の編集を変更しません。基本的な言語の色付けに対応し、通常のファイル訪問フック・ファイルローカル変数は実行しません。

## 設定

```elisp
(setq neo-scope-frame-ratio 0.9       ; 親フレームに対する寸法
      neo-scope-list-ratio 0.4       ; 左ペインの幅
      neo-scope-max-results 10000
      neo-scope-max-file-size (* 1024 1024)
      neo-scope-excluded-directories '(".git" ".hg" ".svn" "node_modules"))
```

テーマの色は `neo-scope-selection`、`neo-scope-match`、`neo-scope-title` faceで調整できます。

## 差し替え・独自ソース

`neo-scope-matcher` で絞り込みと順位付け、`neo-scope-file-source-function` でファイル取得を交換できます。ソースごとに `:matcher`、`:preview`、`:action` を指定できます。

```elisp
(neo-scope-open
 (list :name "Notes"
       :start (lambda (_query emit)
                (funcall emit 'add
                         (list (list :id 'scratch :label "Scratch"
                                     :match "Scratch"
                                     :value (list :buffer (get-buffer-create "*scratch*")))))
                (funcall emit 'done nil)
                #'ignore)))
```

ソースの `:start` は検索文字列と通知関数を受け取り、中止関数を返します。通知は `(funcall emit EVENT PAYLOAD)` です。

| EVENT | PAYLOAD |
| --- | --- |
| `add` | `:id :label :match :value` を持つ候補plistのリスト |
| `done` | `nil`（取得完了） |
| `status` | 状態文字列 |
| `error` | エラー文字列（取得終了） |

`:query-dependent t` を指定すると入力変更時にソースを再起動します。終了後や古い検索の通知は無視されます。同じ `:id` は重複追加されません。`:label` は単一行、`:match` は照合文字列、`:value` は処理用の値です。

マッチャー `(QUERY CANDIDATE)` は非一致ならnil、一致なら `(SCORE . POSITIONS)` を返します。POSITIONSは0始まりの文字位置で、`:label` と `:match` が同じなら強調に使います。スコア降順、同点は取得順を維持します。プレビュー関数 `(CANDIDATE BUFFER)` は指定バッファへ描画し、確定関数 `(CANDIDATE)` はFinderを閉じた後に呼ばれます。

Orderless・Consult・Vertico用の専用アダプターは未実装です。交換APIを使用して後から追加でき、本体に依存を持ち込みません。

## 制限

- 端末・TRAMP検索には対応していません。子フレームを表示できるGUIが必要です。
- `.gitignore` は解釈しません。除外ディレクトリの設定を使用し、シンボリックリンクは追跡しません。
- grepは保存済みのファイル内容を検索します。正規表現検索ではありません。
- バイナリ・サイズ上限超過・読込失敗はスキップし、件数を表示します。候補上限に達した場合も表示します。
- 処理はタイマーで分割しますが、並列I/Oではありません。巨大ディレクトリの列挙や遅いドライブは同期I/Oの待ち時間が残ります。
- 起動中のFinderは1つです。再起動時には前のセッションを閉じます。

## 検証

```powershell
emacs -Q --batch -L . -l tests/neo-scope-tests.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -L . -f batch-byte-compile neo-scope.el
emacs -Q --batch -l tests/neo-scope-package.el
```

GUIテストは独立したEmacsで `-Q -l tests/neo-scope-gui.el` を指定します。テストはそのEmacsプロセスを終了します。先に `build` ディレクトリを作成してください。[検証結果](docs/verification.md)を参照してください。

## 設計

[設計案](docs/superpowers/specs/2026-10-14-neo-scope-design.md)

導入指定の仕様は[use-package公式マニュアル](https://www.gnu.org/software/emacs/manual/html_node/use-package/Install-package.html)を参照してください。
