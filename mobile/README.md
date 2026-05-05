# バス団子シミュレーター mobile

Android 優先の Flutter 版です。`spring/index.html` の主要機能をスマホ向けに再構成しています。

## 機能

- 制御なし / スキップ制御 / スプリング法の同時比較
- 路線アニメーション、要約指標、主要トレンド
- プリセットと詳細パラメータ編集
- 端末内シード平均計算
- 設定JSON、結果JSON、指標CSV、シード平均JSON/CSVのコピー出力
- 設定JSON、シード平均JSONの貼り付け読込

しきい値スイープはスマホ版では対象外です。

## 開発コマンド

```powershell
& "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe" dart format lib test
& "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe" flutter analyze
& "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe" flutter test
& "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe" flutter build apk --debug
```
