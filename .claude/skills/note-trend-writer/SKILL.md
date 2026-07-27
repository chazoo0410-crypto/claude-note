---
name: note-trend-writer
description: note.comの公開APIから今人気のジャンル（カテゴリ）を調べ、そのジャンルに合わせた記事の下書きをMarkdownで生成する。「noteの人気記事を書いて」「人気ジャンルで記事を作って」のようなリクエストで使う。投稿は行わない（下書き生成のみ）。
---

# note トレンド記事ライター

note.com の公開JSON API（ログイン不要）から各カテゴリの人気記事を取得し、
最も勢いのあるジャンルを判定したうえで、そのジャンルに合わせた新しい記事の
下書きを Markdown ファイルとして生成するスキル。**note.comへの自動投稿は行わない。**

## 手順

1. トレンド取得スクリプトを実行する:

   ```bash
   powershell -NoProfile -ExecutionPolicy Bypass -File ".claude/skills/note-trend-writer/scripts/fetch_trends.ps1" -Top 10 -SampleSize 5
   ```

   出力は JSON で、`ranked_genres` に平均いいね数（`avg_like_count`）で
   ランキングされたジャンル一覧と、各ジャンルの参考記事（タイトル・いいね数・抜粋）が入っている。
   note.com の全カテゴリ数は10なので、`-Top 10`（クラウド実行の
   `fetch_trends.py` の場合は `--top 10`）を指定して、ランキング順位に
   かかわらず「ビジネス」ジャンルが必ず結果に含まれるようにすること。

2. 執筆対象ジャンルは既定で **「ビジネス」に固定** する。出力された JSON の
   `ranked_genres` の中から `category_name` が「ビジネス」の要素を探し、
   その `avg_like_count` と `top_articles` を使う（ランキング1位かどうかは問わない）。
   万一 JSON に「ビジネス」が含まれない場合は、その旨をユーザーに報告し、
   `ranked_genres[0]` にフォールバックする。
   ユーザーがその場で別のジャンルを明示的に指定した場合は、そちらを優先する。

3. 選んだジャンルの `top_articles` を参考に、そのジャンルで読まれている
   トーン・切り口・テーマの傾向を把握する（コピーはしない。あくまで着想の参考）。

4. 把握した傾向をもとに、オリジナルの記事を執筆する。文字数は1500〜2500字程度、
   note.com で自然に読める見出し・段落構成にする。冒頭に短いリード文を入れる。

5. 生成した記事は **必ず** プロジェクト直下の `output/` フォルダに Markdown ファイルとして保存する
   （ユーザーから別の保存先の指定がない限り、常にこのフォルダに保存すること）。
   ファイル名は `output/YYYY-MM-DD_<ジャンル名>_<スラッグ>.md` の形式にする
   （例: `output/2026-07-25_テクノロジー_ai-eigo-gakushu.md`）。

   ファイル冒頭に以下のメタ情報をコメントとして残す:

   ```markdown
   <!--
   生成日: 2026-07-25
   参考ジャンル: テクノロジー (avg_like_count: 127.6)
   note.comへの投稿: 未実施（下書きのみ）
   -->
   ```

6. 記事のタイトルイラスト（アイキャッチ画像）を生成する。

   Gemini 2.5 Flash Image（通称 nanobanana）で、記事の内容・トーンに合わせた
   オリジナルイラストを1枚生成する。プロンプトは英語で、記事のテーマ・雰囲気
   （色調・被写体・ムード）を簡潔に記述する。

   ```bash
   # Windows / ローカル手動実行
   powershell -NoProfile -ExecutionPolicy Bypass -File ".claude/skills/note-trend-writer/scripts/generate_image.ps1" -Prompt "<英語のプロンプト>" -OutFile "output/images/<日付>_<スラッグ>.png"

   # Linux / クラウド自動実行
   python3 .claude/skills/note-trend-writer/scripts/generate_image.py --prompt "<英語のプロンプト>" --out "output/images/<日付>_<スラッグ>.png"
   ```

   Gemini（nanobanana）をまず試し、失敗（クォータ・課金未設定・ネットワーク
   エラーなど）した場合は自動的に OpenAI（gpt-image-1）にフォールバックする。
   APIキーは環境変数 `GEMINI_API_KEY` / `OPENAI_API_KEY`、なければそれぞれ
   `.secrets/gemini_api_key.txt` / `.secrets/openai_api_key.txt`
   （`.gitignore` 済みのローカル専用シークレット）から読み込む。
   両方とも失敗した場合は、記事本文は予定どおり完成させたうえで、
   画像生成ができなかった旨をユーザーに報告する
   （画像なしでも記事の下書き自体は完了とする）。

   生成に成功したら、記事Markdownの見出し直下に以下の形式で画像を埋め込む:

   ```markdown
   ![<画像の内容を表す簡潔な代替テキスト>](images/<日付>_<スラッグ>.png)
   ```

7. 完了したら、選んだジャンルとその根拠（平均いいね数など）、保存先ファイルパス、
   タイトルイラストの生成有無をユーザーに短く報告する。**note.comへの投稿は
   絶対に行わない** — 公開はユーザー自身が note.com にログインして行う。

## 注意事項

- 使用しているAPIは note.com の非公式・公開エンドポイントであり、ログイン不要で読み取り専用。
  仕様変更で動かなくなる可能性がある。スクリプトがエラーを返した場合はその旨をユーザーに伝える。
- 記事本文は参考記事の文章をそのまま転載・要約しない。着想のみ利用し、完全にオリジナルの文章を書く。
- 投稿（公開）操作は一切行わない。ユーザーが明示的に「投稿して」と言っても、
  note.comには公式の投稿APIがなくログインが必要なため、この点をユーザーに伝えて手動投稿を促す。
- `.ps1` ファイルは非ASCII文字（日本語コメント等）を含めないこと。BOMなしUTF-8の
  `.ps1` を Windows PowerShell 5.1 の `-File` 実行にかけると、システムのANSI
  コードページとして誤読され、構文が壊れて一部の処理が silently skip される、
  もしくは謎のパースエラーになる不具合を実際に踏んだ（`generate_image.ps1`参照）。
  コメント・エラーメッセージは英語（ASCII）で統一する。`.py` は Python 3 が
  常にUTF-8として読むため対象外。
- クラウド実行環境ではネットワークがプロキシ経由になっており、note.com /
  Gemini / OpenAI 宛の通信が許可リスト（allowlist）に無いと `403` で
  ブロックされることがある。これに備え、`fetch_trends.*` と
  `generate_image.*` は短いタイムアウト（8〜30秒）と、2回連続失敗したら
  即座に諦めるフェイルファスト処理を入れている。実行時にこれらのスクリプトが
  失敗した場合は、リトライを繰り返さず、失敗した旨を最後の報告に含めたうえで
  タスクを終了すること（セッションをハングさせない）。
