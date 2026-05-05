# だんごバス3台 mobile

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

## Android実機で動かす

PowerShellで `mobile/` に移動してから実行します。

```powershell
cd C:\Users\suzuk\Desktop\apps\bus_bunching\mobile
```

接続された端末を確認します。

```powershell
& "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe" flutter devices
```

`Device ... is not authorized` と出る場合は、Android端末側に表示されるUSBデバッグ許可ダイアログで許可します。表示されない場合は、USBケーブルを挿し直す、端末の開発者向けオプションでUSBデバッグを一度オフ/オンする、または端末のUSB接続モードを「ファイル転送」に変更してから、もう一度 `flutter devices` を実行します。

端末が認識されたら、次のコマンドで実機へインストールして起動します。

```powershell
& "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe" flutter run
```

複数デバイスが表示される場合は、`flutter devices` の左側に出る端末IDを指定します。

```powershell
& "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe" flutter run -d 61171FDCR000NT
```

`flutter run` 中は、PowerShell上で `r` を押すとホットリロード、`R` を押すとホットリスタート、`q` を押すと終了できます。

APKだけ作って手動インストールしたい場合は、debug APKをビルドします。

```powershell
& "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe" flutter build apk --debug
```

生成先は次です。

```text
build\app\outputs\flutter-apk\app-debug.apk
```
