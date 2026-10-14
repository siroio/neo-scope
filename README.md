# neo-scope

Emacs標準機能だけで動くFuzzy Finderです。通常フレーム内に、左に候補一覧と検索欄、右にコードプレビューを表示します。Vertico・Consult・Orderless・posframe・外部実行ファイルは実行時に不要です。

GUI Emacs 29.1以降を対象とします。Windows / Emacs 31.1で自動検証しています。他OSと実際のIME入力は未検証です。

動画・音声の詳細情報は任意の `ffprobe` を使います。未導入でも検索、基本情報、テキストと対応画像のプレビューは動作します。

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
| `q` | 候補・プレビューペインから閉じる（入力欄では検索文字） |
| `C-x k` | バッファを閉じ、検索画面全体を終了する |
| `M-p` / `M-n` | 検索履歴 |
| `C-x o` | 各ペインへ移動 |

確定・キャンセル・候補移動は全ペインで使用できます。バッファ一覧には `*neo-scope*` を表示し、候補とプレビューは内部バッファとして管理します。どのペインのバッファを閉じても検索画面全体を終了し、開く前のウィンドウ分割・選択位置へ戻ります。プレビューは読み取り専用で、元のバッファや未保存の編集を変更しません。基本的な言語の色付けに対応し、通常のファイル訪問フック・ファイルローカル変数は実行しません。

## ファイル情報とプレビュー

右ペインは選択ファイルの種類に応じて表示を切り替えます。

| 種類 | 内容 |
| --- | --- |
| 共通 | ファイル名、絶対パス、サイズ、更新日時。バッファに未保存の変更があれば併記 |
| テキスト・コード | 共通情報と色付けした本文。grepの該当行へ移動 |
| 画像 | 形式、元画像の縦横サイズ、ペイン内に収まる画像プレビュー |
| 動画 | コンテナー形式、再生時間、映像ストリームごとの解像度・コーデック・FPS・ビットレート |
| 音声 | 再生時間、音声ストリームごとのコーデック・ビットレート・サンプルレート・チャンネル |

PNG/JPEG/GIF/WebP/BMP/TIFF/SVG/AVIF/ICO等の画像を振り分け、実際に表示できる形式はEmacsのビルドに従います。未対応形式やサイズ上限超過でも基本情報を残します。動画・音声はMP4/MKV/WebM/MOV/AVI/M4V/MPEG/WMV、MP3/WAV/FLAC/OGG/Opus/M4A/AAC/WMA/AIFF等を対象とします。動画再生・サムネイル生成は行いません。

`ffprobe` がPATH上にあれば自動で利用します。独自配置なら `neo-scope-ffprobe-program` に実行ファイルのパスを指定でき、nilで無効にできます。取得できない項目は `Unknown` と表示します。

基本情報を先に表示し、詳細は非同期で更新します。候補移動・検索語変更・画面終了時には取得を中止し、古い結果が別の候補を上書きしないようにしています。成功したメディア情報を最大64件キャッシュし、パス・サイズ・更新日時・属性変更日時・実行ファイルの組み合わせで再利用を判定します。必要なら `M-x neo-scope-clear-preview-cache` で消去できます。

取得は既定5秒で打ち切り、プロセスの出力にも上限があります。失敗時は基本情報と理由を表示し、失敗結果はキャッシュしません。画像の読み込み・デコードとファイル属性取得はEmacsの同期処理です。

## 設定

```elisp
(setq neo-scope-list-ratio 0.4       ; 左ペインの幅
      neo-scope-max-results 10000
      neo-scope-max-file-size (* 1024 1024)
      neo-scope-max-image-size (* 20 1024 1024)
      neo-scope-ffprobe-program "ffprobe" ; nilでメディア取得を無効化
      neo-scope-probe-timeout 5
      neo-scope-media-cache-size 64
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

## Consult・Orderless・Verticoとの任意連携

各パッケージは必要な機能を呼ぶときだけ読み込みます。自動インストールはしません。未導入の場合は自作の検索・照合・表示へ戻ります。

neo-scopeの画面を維持し、Orderlessによる照合とConsultのripgrepを利用する設定です。

```elisp
(use-package neo-scope
  :vc (:url "https://github.com/siroio/neo-scope" :rev :newest)
  :commands (neo-scope-find-file neo-scope-buffer neo-scope-grep)
  :custom
  (neo-scope-list-ratio 0.4)
  (neo-scope-matcher #'neo-scope-orderless-match)
  (neo-scope-file-source-function #'neo-scope-consult-file-source))
```

- **Orderless**: ファイル・バッファ検索を複数単語で絞り込みます。`beta alpha` は `alpha beta` に一致し、日本語、設定済みのmatching styles・dispatchers・大文字小文字設定も使用します。スコアは同点として取得順を維持します。
- **Consult**: `neo-scope-grep` の候補取得をConsultのripgrepへ交換します。`rg` が必要です。`consult-ripgrep-args`、正規表現の生成とcase設定を使用し、ファイルと行番号をneo-scopeのプレビュー・確定処理へ渡します。通常のファイル一覧取得は自作処理です。grepの検索語はConsultが処理するため、結果をOrderlessで再照合しません。
- **Vertico**: 同じ3コマンドの選択画面をミニバッファへ変更できます。

```elisp
;; Verticoで選ぶモード。neo-scopeの:customに追加できます。
(setq neo-scope-display-function #'neo-scope-vertico-open)

;; neo-scopeの候補・プレビュー画面に戻す
(setq neo-scope-display-function #'neo-scope-open)
```

Verticoモードでは候補を収集してから選択します。grepは「検索語入力 → 検索結果を選択」の2段階で、選択中の検索プロセス再起動やneo-scopeのプレビュー画面は使用しません。候補ラベルには識別番号を付け、同名の候補も別々に選べます。照合は通常のcompletion設定を使用し、Orderless連携を選択済みならこの選択中だけOrderlessを使用します。Verticoが無効なら選択中だけ有効にし、取消・エラー時も元の有効状態へ戻します。

収集は `neo-scope-collection-timeout`（既定30秒）で打ち切り、C-g・エラー・終了時にソースを中止します。Consult連携は候補取得専用の安定した公開APIがないため内部のbuilder・process APIをこのアダプター内で利用します。API未提供またはConsult/rg未導入なら自作grepへ戻ります。内部APIの将来変更には追従が必要です。プロセス失敗とrgの「一致なし」はどちらも終了扱いとし、診断先 `*consult-async*` を状態欄に表示します。

既存の `consult-*` コマンドやグローバルのcompletion設定は変更しません。

## 制限

- 自作画面はGUI専用です。Verticoモードは通常のミニバッファを使用します。TRAMP検索には対応していません。
- 自作ソースは `.gitignore` を解釈しません。除外ディレクトリの設定を使用し、シンボリックリンクは追跡しません。Consultのripgrepソースはrgの設定に従います。
- grepは保存済みのファイル内容を検索します。自作ソースはリテラル文字列、Consultソースは正規表現検索です。
- grepではバイナリ・サイズ上限超過・読込失敗をスキップし、件数を表示します。候補上限に達した場合も表示します。プレビューでは基本情報を残して、本文や詳細を表示できない理由を示します。
- 処理はタイマーで分割しますが、並列I/Oではありません。巨大ディレクトリの列挙や遅いドライブは同期I/Oの待ち時間が残ります。
- 起動中のFinderは1つです。再起動時には前のセッションを閉じます。

## 検証

```powershell
New-Item -ItemType Directory -Force build/tmp
emacs -Q --batch -L . --eval '(setq temporary-file-directory (expand-file-name "build/tmp"))' -l tests/neo-scope-tests.el -l tests/neo-scope-media-tests.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -L . -f batch-byte-compile neo-scope.el
emacs -Q --batch -l tests/neo-scope-package.el
```

GUIテストは独立したEmacsで `-Q -l tests/neo-scope-gui.el` を指定します。テストはそのEmacsプロセスを終了します。先に `build` ディレクトリを作成してください。[検証結果](docs/verification.md)を参照してください。

メディアの実機テストとfixture生成手順は[メディア検証記録](docs/media-verification.md)を参照してください。

任意連携の実パッケージ・GUI検証は[連携検証記録](docs/integrations-verification.md)を参照してください。

## 設計

[設計案](docs/superpowers/specs/2026-10-14-neo-scope-design.md)

導入指定の仕様は[use-package公式マニュアル](https://www.gnu.org/software/emacs/manual/html_node/use-package/Install-package.html)を参照してください。
