# muziy ショップサイト

ハンドメイドアクセサリー **muziy** のショップサイト（たたき台）です。
サーバー不要で、`index.html` をブラウザで開くだけで動きます。

```
muziy-shop/
├── index.html            ページ本体（文章はここ）
├── assets/
│   ├── styles.css        配色・レイアウト
│   ├── products.js       ★ 商品データ（ここを編集します）
│   ├── app.js            カート・詳細パネル・仮イラストの描画
│   └── photos/           ★ 商品写真を入れるフォルダ
└── README.md
```

## 商品写真の入れかた

1. 写真を `assets/photos/` に入れます。縦長 **4:5**（例 1000×1250px）に切り出しておくと、そのまま収まります。
2. `assets/products.js` の該当する商品の `image` を書き換えます。

```js
image: "assets/photos/01-ruri.jpg",
```

`image: null` にすると、写真ができるまでのあいだ、素材の色にあわせた線画が自動で描かれます。

## 商品の追加・編集

`assets/products.js` の1商品ぶんをコピーして書き換えてください。

| 項目 | 内容 |
| --- | --- |
| `no` | 作品番号（`"09"` のように2桁の文字列） |
| `name` / `reading` | 作品名と読みがな |
| `sub` | 一行説明（例「淡水パールのピアス」） |
| `category` | `ブレスレット` `イヤリング・ピアス` のいずれか |
| `price` | 税込価格（数字のみ） |
| `stock` | 在庫数。`0` にすると SOLD OUT 表示になります |
| `oneOff` | `true` にすると「一点もの」と表示されます |
| `image` | 写真のパス。まだなら `null` |
| `kind` | 仮イラストの形（`drop` `hoop` `cluster` `stud` `bar` `pendant` `clip` `band`） |
| `tone` | 仮イラストの色（`pearl` `gold` `brass` `shell` `stone` `resin`） |
| `note` | 作品の紹介文 |
| `spec` | 仕様表。項目名は自由に増やせます |

カテゴリを増やしたときは、`index.html` の `.filters` にボタンを1つ足してください。

## 送料などの設定

`assets/app.js` の先頭にあります。

```js
const INSTAGRAM = "https://www.instagram.com/muziy.696";
const SHIPPING  = 370;    // 送料
const FREE_OVER = 5000;   // この金額以上で送料無料
```

## ご注文の流れ

オンライン決済はまだ入れていません。カートで「ご注文内容をまとめる」を押すと、
そのまま送れる注文メモができるので、コピーして Instagram のDMからお送りいただく流れです。
決済を導入する場合も、このカートの計算をそのまま使えます。
