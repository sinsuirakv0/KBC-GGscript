# KBC-rakv0-status-script

GameGuardian 用のステータス変更スクリプトの実験環境です。`unit000.csv` をネコ、`unit001.csv` をタンクネコ系の次ユニットとして、元の `unit001.csv` からゼロ始まりへ変換します。

## 使用手順

1. `tools/build-data.ps1` を実行して、復号済み `DataLocal` から実行用CSVを生成する。
2. `tools/export-test-package.ps1` を実行する。
3. `dist/KBC-rakv0-status-script` を端末の Download などへコピーする。
4. GameGuardian でにゃんこ大戦争を対象にしてから、`lua/kbc-status-test.lua` を実行する。

Lua は `unit-names.csv` と変換済み `data/units/unitNNN.csv` を読む。値の入力は元のCSV値で行い、ネイティブコードで確認した倍率を適用して DWORD に書き込む。

ゲーム由来の復号済みデータとAndroid用配布物は `.gitignore` で除外している。GitHubへは変換器、Lua、設計資料だけを置く。
