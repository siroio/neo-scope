# ファイル情報・メディアプレビュー検証

2026-10-14、Windows / Emacs 31.1。変更範囲はneo-scopeのみ。既存emacs.d、導入済みコピー、親submodule参照は変更していない。commit・pushは未実施。

## 実装

共通メタデータ、コード本文、画像プレビューを提供し、任意のffprobeで動画・音声の情報を補う。本体の外部Elisp依存は増やしていない。ffprobeの起動は引数リストを使い、シェルを介さない。詳細表示は全ストリームを扱い、欠落値はUnknownとする。

選択・入力変更と終了時に所有する取得プロセスを中止し、バッファのトークンでも古い結果を拒否する。上限付きキャッシュはファイル属性が変わると無効になる。成功だけをキャッシュする。画像はEmacsのデコード機能を使い、同期処理になる。

## 検証

- 通常ERT 31件と実ffprobe統合2件、合計33件成功。
- バイトコンパイルは警告・エラーなし。
- PNG 320x180、MP4 MPEG-4映像25fps＋AAC音声44.1kHz、WAV PCM 22.05kHz・2chをneo-scope/build内に生成して確認。
- メディアGUI: 画像の元サイズ・display属性、動画FPS・音声ストリーム、WAVのサンプルレート・コーデック、終了後にプロセスが残らないことを独立GUIで確認。
- タイムアウト、中止、重複中止、遅延結果、バッファ破棄、キャッシュ再利用・更新無効化・件数上限、JSON破損、出力上限、実際の壊れたメディア、ffprobe未導入、画像形式未対応を検証。
- 共通情報に引用符を含むバッファ名を表示しても本文の構文色付けが変わらないことを、レビューでの再現後に回帰テスト化して修正。
- Windowsでは引数にlocale-coding-system、出力にはUTF-8を使う。日本語と空白を含む動画ファイル名で実ffprobeを確認した。

全画像形式・全コーデック・全OSの網羅試験ではない。Emacs 29/30、他OS、IME実入力は未検証。Windowsのシステムコードページで表せないファイル名も未検証。通常の画像・メディアを選択するUIの構造は自動確認したが、実マウス操作の体感・ピクセル単位の見た目は未検証。

## 再実行

以下はneo-scopeをカレントディレクトリにして実行する。生成物はすべてbuild内。fixture生成にffmpeg、メディア検証にffprobeを使う。これらを自動インストールすることはない。

```powershell
New-Item -ItemType Directory -Force build/tmp,build/media-fixtures
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=blue:s=320x180:r=25 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 0.4 -c:v mpeg4 -c:a aac 'build/media-fixtures/動画 sample.mp4'
ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=220:sample_rate=22050 -t 0.3 -ac 2 'build/media-fixtures/audio.wav'
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=green:s=320x180 -frames:v 1 'build/media-fixtures/image.png'
emacs -Q --batch -L . --eval '(setq temporary-file-directory (expand-file-name "build/tmp"))' -l tests/neo-scope-tests.el -l tests/neo-scope-media-tests.el -l tests/neo-scope-media-integration.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -L . -f batch-byte-compile neo-scope.el
```

独立GUIプロセスに `-Q -l tests/neo-scope-media-gui.el` を指定する。テストはそのプロセスを終了し、build/media-gui-result.txtへ結果を書く。普段使うEmacsへテストをロードしない。
