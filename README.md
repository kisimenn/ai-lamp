# AI通知ランプ 設定手順（AI向け）

この文書は、お客さんに頼まれた AI（Claude Code または Codex）が読んで実行するための手順です。
AI の作業状態を USB ランプの色で知らせます（作業中=青 / 完了=緑 / あなたの出番=橙）。

## AI への約束ごと（必ず守る）
- **スクリプトや設定を自分で書かない。** 下に書いたコマンドだけを、書いたとおりに実行する。設定ファイル（settings.json・hooks.json・config.toml）を手で編集しない。
- **COM ポートを自分で調べて判断しない。** ランプが見つかるかどうかは、スクリプトが表示する結果をそのまま伝える。
- お客さんは機械に詳しくないことが多い。専門用語を避けて、やさしい日本語で短く話す。
- お客さんにしてもらうのは「コマンドの実行を許可する」「（Windows のときだけ）既読で消える機能を使うか答える」「ランプが光ったか答える」「アプリを開き直す」「（Codex のときだけ）フックを1回承認する」だけにする。
- クラウドで動く版（Web の Claude Code、Codex のクラウド）では使えない（パソコンの USB に届かないため）。その場合はそう伝えて終わる。

## はじめに：どれに当てはまるか
| 使っている AI | パソコン | 進む先 |
|---|---|---|
| Claude Code | Windows | 「1. ダウンロード（Windows）」 |
| Claude Code | Mac | 「1. ダウンロード（Mac）」 |
| Codex | Windows | 「1. ダウンロード（Windows）」。最後に「4. Codex のフックを承認」も行う |
| Codex | Mac | 「1. ダウンロード（Mac）」。最後に「4. Codex のフックを承認」も行う |

どちらの AI でも同じ設定スクリプトを使います。スクリプトが、パソコンに入っている Claude Code と Codex の両方をまとめて設定します。

最初にお客さんへ一言伝える:「ランプの設定ファイルをダウンロードして、設定を実行します。途中で実行の許可を求められたら許可してください。」
Mac のときは、あわせて「ランプを挿したときに『アクセサリの接続を許可しますか？』と出たら、『許可』を押してください」と伝える（許可しないとランプと通信できない）。

## 1. ダウンロード（Windows）
PowerShell で、次をそのまま実行する（`%USERPROFILE%\.cache\ai-lamp\src` に置く）。
```powershell
$d = Join-Path $env:USERPROFILE '.cache\ai-lamp\src'; Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path $d | Out-Null; Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/kisimenn/ai-lamp/archive/refs/heads/main.zip' -OutFile (Join-Path $d 'repo.zip'); Expand-Archive -Force (Join-Path $d 'repo.zip') $d; Get-ChildItem $d -Directory | Select-Object -ExpandProperty FullName
```
最後に表示されたフォルダ（`...\ai-lamp-main`）を、次の手順で使う。

## 1. ダウンロード（Mac）
ターミナルで、次をそのまま実行する（`~/.cache/ai-lamp/src` に置く）。
```bash
d="$HOME/.cache/ai-lamp/src"; rm -rf "$d"; mkdir -p "$d" && curl -fsSL -o "$d/repo.zip" https://github.com/kisimenn/ai-lamp/archive/refs/heads/main.zip && unzip -q -o "$d/repo.zip" -d "$d" && ls -d "$d"/*/
```
最後に表示されたフォルダ（`.../ai-lamp-main/`）を、次の手順で使う。

## 2. 設定を実行
**Windows のときだけ、実行する前に1回だけ聞く**:「ランプが緑か橙に点いたあと、AI のアプリの画面でマウスかキーボードを触ると、ランプが消える機能（既読で消える機能）を使いますか？」
- 使う → 下の Windows のコマンドの最後に ` -Watch` を付ける
- 使わない → ` -NoWatch` を付ける
- Mac にはこの機能が無いので聞かない

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "<1で表示されたフォルダ>\setup.ps1" -Watch`（使わないときは `-NoWatch`）
- Mac: `bash "<1で表示されたフォルダ>/setup.sh"`

結果は「OK（成功）」「--（飛ばした）」「NG（失敗）」で1行ずつ表示される。**区別したまま**、短くお客さんに伝える。
最後の行がランプの確認で、ランプが見つかれば緑に2秒光る。お客さんに **「ランプが緑に光りましたか？」** と聞く。

- 光った → 「3. アプリを開き直す」へ
- 光らない → 「5. 光らないとき」へ

## 3. アプリを開き直す
スクリプトの最後の案内のとおり、**設定したアプリだけ**を終了して開き直してもらう。
- **見本の画像は、案内する前にお客さんのブラウザで開いておく**（アプリを閉じても、ブラウザの画像は残って見ながら操作できる）。Windows: `Start-Process '<画像のURL>'`、Mac: `open '<画像のURL>'`
- Windows の Claude アプリは、右上の × では裏で動き続けることがある。左上の「≡」→「ファイル」→「終了」で終了してもらう。画面の見本: https://raw.githubusercontent.com/kisimenn/ai-lamp/main/docs/claude-quit.png
- Windows の Codex アプリは、右上の × では裏で動き続けることがある。メニューの「ファイル」→「ChatGPT を終了」で終了してもらう（Codex でもメニューには ChatGPT と出る）。画面の見本: https://raw.githubusercontent.com/kisimenn/ai-lamp/main/docs/codex-quit.png
- Mac は Command + Q で終了。
- 開き直したら新しい会話で何か頼んでもらい、**青 → 緑** と光るか確かめてもらう。
- 2 の緑2秒は「ランプが見つかった」確認で、AI との連動の確認ではない。この2つを混ぜて「連動も確認済み」と言わない。

## 4. Codex のフックを承認（Codex を使っている人だけ・1回だけ）
Codex は、ランプ用のフックを1回承認しないと光らない（承認するまで黙って飛ばされる）。必ず伝える。
- Codex アプリ: 入力欄の下に出る、**黄色い点付きのフックのアイコン** →「フックの確認」で、`lamp-hook` または `lamp.ps1`（Mac は `lamp.pl`）と書かれたランプ用のフックを許可する。全部ランプ用なら「すべて許可」、ほかのフックも並んでいれば**ランプ用だけ**選んで「選択した項目を許可」。これで完了。
- アイコンの画像: https://raw.githubusercontent.com/kisimenn/ai-lamp/main/docs/hook-icon.png （3 と同じく、ブラウザで開いて見せる）
- アイコンのとなりの文字は Codex の設定で変わるので、目印にしない。
- アイコンが出ないときは、承認済みのこともある。設定 → Hooks で確かめてもらう（決めつけない）。
- ターミナルの Codex は `/hooks` で承認する。
- 同じ承認を二か所で求めない。承認済みと分かったら何度も頼まない。
- Codex で橙になるのは「許可を求められたとき」だけ（Codex にはエラーで止まった合図が無い）。

## 4.5 最後に、光り方を変えられることを紹介する
開き直し（と Codex のフック承認）を伝えたあとに、短く紹介する。押しつけず「気が向いたら」くらいで。
> ちなみに、ランプの光り方は、私に頼めば変えられます。たとえば、
> - 「作業中の色を紫にして」
> - 「夜は暗くして」
> - 「作業が終わったら虹色でお祝いして」
> - 「作業が10分を超えたら色を変えて」
> - 「やさしい光り方にして」（ほかに 派手・夜用・集中）
> 気が向いたら言ってください。

頼まれたら、ランプのスキル（lamp-setup）の「光り方を変えて と言われたら」のとおりに、好みのファイルだけを書き換える。

## 5. 光らないとき（この順で、深追いしない）
1. 「ランプを USB から抜いて、挿し直してください。**虹色**に光りましたか？」と聞く。
2. 虹色に光らない → 別の USB ポートに挿してもらう。USB ハブを使っていれば外して、パソコンに直接挿してもらう。
3. 虹色に光った → （Mac のときは）「挿したときに『アクセサリの接続を許可しますか？』と出ましたか？『許可しない』を押していたら、もう一度挿し直して『許可』を押してください」と聞く。そのうえで、ランプの確認だけをやり直す:
   - Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "<1のフォルダ>\plugins\ai-lamp\scripts\lamp-test.ps1"`
   - Mac: `/usr/bin/perl "<1のフォルダ>/plugins/ai-lamp-mac/scripts/lamp.pl" test`
   表示された結果をそのまま伝え、緑に光ったか聞く。
4. Arduino IDE などシリアル通信を使うソフトが開いていれば、閉じてもらってからもう一度 3。
5. **2回やってもだめなら**、パソコンを再起動してから、もう一度この手順を最初から頼んでもらうよう伝えて終わる。

## 外したいと言われたら
1 と同じ方法でダウンロードし、Windows は `uninstall.ps1`、Mac は `uninstall.sh` を実行する（Claude Code のプラグイン、Codex のフック、ランプの記録をまとめて外す）。そのあとアプリを開き直してもらう。
