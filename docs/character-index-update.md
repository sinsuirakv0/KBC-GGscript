# キャラ索引とアプリ内更新

## データの読み込み

Lua本体は `data/character-index.json` をキャラ索引として読み込む。`units` はID順の連続配列であり、各要素の `id` は配列位置と一致する必要がある。

- `forms`: 配列順を第1～第4形態として扱う。`name` を表示名、`description` を保持する。
- `aliases`: キャラ単位の検索用別称として扱う。第1形態名・全形態名と同じ部分一致検索に使う。
- `Data/unit001.csv` はキャラID `000` に対応するため、取得後は `data/units/unit000.csv` として保存する。以後もソースIDはキャラIDに1を加えた値で対応付ける。

古い `unit-index.csv` は参照しない。

## ステータス表の探索

v15.6.0 のネイティブCSVローダーは、1形態を118個のDWORD（`0x1D8`バイト）、1キャラを4形態（`0x760`バイト）として保持する。`status-fields.csv` の行数を唯一の列数として使い、列を追加した場合も同じ値からレコードサイズを再計算する。

ユニット表の探索はネコのCSV値だけで候補を絞り、複数形態の安定した列を照合して確定する。照合値の形態番号は「照合に使う列数」単位で求める必要がある。列数ではなくCSV先頭の固定列数で区切ると、後続形態の一致数が別の形態へ誤配分され、正しい表も不一致になる。

`全unit CSV` の更新元はDataLocal由来の生CSVであり、旧パッケージに同梱していたメモリ単位のCSVとは異なる。読込時に、生コストのネコが`50`であることを識別して、ネイティブローダーと同じ先頭列の倍率（速度・時間×2、射程・幅×4、コスト×100）と短い行の既定値を適用する。既に変換済みのCSVは二重変換しない。

## 更新処理

ホームの `設定` にある `スクリプトとデータを更新` は、次のraw URLを `gg.makeRequest` で取得する。

- `KBC-GGscript/main/lua/KBC-GGscript.lua`
- `KBC-rakv0-assets/main/jp/sitedata/character-index.json`
- `KBC-rakv0-assets/main/jp/sitedata/Data/unit%03d.csv`

スクリプトは、索引JSONの構造を検証してから、索引にある全ユニットCSVをメモリ上へ取得・検証する。取得が完了した後にJSONとCSVを保存し、Lua本体は最後に上書きする。通信・形式検証に失敗した場合は、それまでに保存を開始しない。

各ファイルは `raw.githubusercontent.com`、GitHubのraw URL、jsDelivr CDNの順で取得を試みる。いずれかが一時的に404・通信失敗となっても、次の配布URLから同じファイルを取得できれば更新を継続する。

更新したLua本体は実行中のLuaを置き換えるだけなので、次回起動時から有効になる。`settings/` と `status-saves/` は更新しない。

取得したLuaに `KBC_CHARACTER_INDEX_UPDATE=1` の互換性識別子がない場合は、旧Luaで更新機能を失わないようLua本体を上書きせず、JSONとユニットCSVだけを更新する。GitHub側へこの版のLuaを公開した後は、Lua本体も同時に更新される。
