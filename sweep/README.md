# バス団子運転 Sweep Lab

`spring/` の3方式比較シミュレーターを元にした、Pythonベースの大量試行・パラメータスイープ用サブプロジェクトです。

制御なし / スキップ制御 / スプリング法を、同じ乱数シード・同じ需要イベントで比較しながら、任意パラメータを1変数または複数変数でスイープできます。計算結果はParquetとJSONで保存し、Streamlit + Plotlyのダッシュボードで確認します。

## 実行方法

この `sweep/` ディレクトリで実行します。

```powershell
python -m bus_sweep.cli run --config configs/default_experiment.json --out runs/default --workers auto --engine fast
python -m bus_sweep.cli summarize --run runs/default
streamlit run bus_sweep/dashboard.py -- --runs runs
```

`run` は既存の出力ディレクトリを上書きする前に、自動で `<outの親>` 直下へ退避します。たとえば `--out runs/default` の既存結果は、`runs/springGainSecPerStop-springDeadbandStops__seeds...__scenarios...__YYYYMMDD-HHMMSS` のような名前で保存されます。バックアップ名にはスイープパラメータ、seed数、シナリオ数、時刻を含めます。configの `name` はフォルダ名には使いません。

バックアップを無効化する場合は `--no-backup`、保存先を変える場合は `--backup-root <dir>` を指定します。

`summarize` は派生データを書き出して要約を表示した後、完了済みの `runs/default` を同じ命名規則のフォルダへリネームします。これにより、通常の `streamlit run bus_sweep/dashboard.py -- --runs runs` でバックアップ済み・確定済みのrunをそのまま選べます。リネームを止める場合は `summarize --no-rename` を指定します。

Codexの動作確認用runは、通常結果と混ざらないように `runs/_codex/` 配下へ作成します。

軽い動作確認には `configs/smoke_experiment.json` を使います。

```powershell
python -m bus_sweep.cli run --config configs/smoke_experiment.json --out runs/smoke --workers 2 --chunk-size 2 --engine fast
python -m bus_sweep.cli summarize --run runs/smoke
```

精密確認には `--engine audit` を使います。`fast` は全探索を短くするための高速モード、`audit` は現行の固定ステップに近い検証モードです。

```powershell
python -m bus_sweep.cli benchmark --config configs/default_experiment.json --seeds 50 --workers 1 --engine fast
```

## 出力ファイル

- `manifest.json`: 実験条件、PC構成、worker数、開始・終了時刻
- `results.parquet`: seed単位のスカラー指標
- `aggregate.parquet`: scenario / mode / metric ごとの平均、標準偏差、件数
- `history.parquet`: scenario / mode ごとの平均時系列
- `candidates.parquet`: 採用候補、制約付き総合点、判定、注意理由
- `metric_surfaces.parquet`: 地形図・ヒートマップ用の派生データ
- `mode_deltas.parquet`: plain / skip / spring の差分可視化用データ
- `progress.jsonl`: 進捗、処理速度、エラーイベント

`runs/` は大量生成されるためgit管理対象外です。

既存の `results.parquet` / JSON / CSV は旧スキーマのままです。`deniedPassengers` などの乗車不可指標や、`control*` に変更した制御スキップ指標で比較する場合は、実験を再実行してください。

## 結果の見方

ダッシュボードでは、まず「地形図」を見ます。

- 地形図: ゲイン×不感帯などの探索空間を、青=良い / 赤=悪いのヒートマップで確認します。
- 変数断面: 横軸に1つのスイープ変数、縦軸に指標を取り、他の変数を固定して3方式の推移を比較します。選択指標の大判グラフに加え、重視度3以上の指標を小型グラフで一覧表示します。
- 候補ポートフォリオ: Pareto散布図と候補ランキングで、採用候補の位置づけを確認します。
- 方式差分: plain → skip → spring の変化をスロープ図と差分バーで確認します。
- リスク: 保持、スキップ、総所要悪化などの副作用分布を確認します。
- 詳細: 表、CSV出力、メタデータ、時系列を確認します。

採用判断では、まず重視度4の補正総所要時間・待ち時間を見ます。次に重視度3の車間安定、完了乗客数、終了時点の未処理需要、副作用で除外条件を確認します。
ダッシュボードの地形図では、重視度3以上の指標をデフォルト表示します。重視度2以下は補助・診断として、折りたたみ内や詳細タブで確認します。

## 指標の重視度

| 重視度 | 指標 | 内部名 | 良い方向 | 使いどころ |
| --- | --- | --- | --- | --- |
| 4 | 補正平均総所要時間 | `adjustedAvgTotalMin` | 小さいほど良い | 完了済み・乗車中・待機中の全発生乗客を含めた平均総所要時間です。未完了者が多い方式を甘く見ない最重要指標です。 |
| 4 | 補正上位5%総所要時間 | `adjustedTop5TotalMin` | 小さいほど良い | 補正総所要時間の悪い側です。極端に不利な乗客が残っていないか見ます。 |
| 4 | 平均待ち時間 | `avgWaitMin` | 小さいほど良い | 乗車できた乗客の、発生から乗車までの平均です。利用者が実感しやすい改善を見ます。 |
| 4 | 上位5%待ち時間 | `top5WaitMin` | 小さいほど良い | 乗車できた乗客の待ち時間95パーセンタイルです。平均だけ改善して一部利用者が悪化していないか見ます。 |
| 3 | 車間RMSE | `headwayRmseStops` | 小さいほど良い | 終了時点の車間が理想車間からどれだけずれているかを見ます。 |
| 3 | 最大車間 | `maxHeadwayStops` | 小さいほど良い | 終了時点の最大空白区間です。大きいほど待ち時間の偏りにつながりやすいです。 |
| 3 | 最小車間 | `minHeadwayStops` | 大きいほど良い | 終了時点の最小車間です。小さすぎる場合は団子状態に近いです。 |
| 3 | 完了乗客数 | `completed` | 多いほど良い | 期間内に目的地へ到着した乗客数です。少ない候補は他指標の信頼性にも注意します。 |
| 3 | 待機中人数 | `waitingNow` | 小さいほど良い | 期間平均ではなく、終了時点で停留所にまだ待っている人数です。未処理需要の残りを見ます。 |
| 3 | 乗車不可影響人数 | `deniedPassengers` | 小さいほど良い | 制御スキップまたは満員で、一度以上来たバスに乗れなかった人数です。利用者負担の代表指標です。 |
| 3 | 乗車不可平均追加待ち | `deniedAvgExtraMin` | 小さいほど良い | 乗車不可を受けた人のうち実際に乗車できた人について、初回乗車不可から実乗車までの平均時間です。 |
| 3 | 乗車不可最大追加待ち | `deniedMaxExtraMin` | 小さいほど良い | 乗車不可を受けた人のうち実際に乗車できた人について、初回乗車不可から実乗車までの最大時間です。 |
| 3 | 制御スキップ人数 | `controlSkippedPassengers` | 小さいほど良い | 期間中に一度以上、制御スキップで乗車を見送られた人数です。 |
| 3 | 制御スキップ平均追加待ち | `controlSkipAvgExtraMin` | 小さいほど良い | 制御スキップされた人の、初回制御スキップから実乗車までの平均時間です。 |
| 3 | 制御スキップ最大追加待ち | `controlSkipMaxExtraMin` | 小さいほど良い | 制御スキップされた人の追加待ち最大値です。 |
| 3 | スプリング保持累計 | `totalSpringHoldMin` | 過大なら悪い | spring制御でバスを保持した累計時間です。改善との釣り合いを見ます。 |
| 3 | 前車待ち遅延累計 | `totalBlockedDelayMin` | 小さいほど良い | 停留所バース詰まりで前車を待った遅延の累計です。 |
| 3 | 平均遅延 | `avgDelayMin` | 小さいほど良い | 終了時点の各バス遅延の平均です。運行全体が遅くなりすぎていないか見ます。 |
| 3 | 最大遅延 | `maxDelayMin` | 小さいほど良い | 終了時点で最も遅れているバスの遅延です。局所破綻を見ます。 |
| 2 | 複数回制御スキップ人数 | `multiControlSkippedPassengers` | 小さいほど良い | 2回以上、制御スキップされた人数です。公平性上の副作用を見ます。 |
| 2 | 制御スキップ後満員影響人数 | `fullDeniedAfterControlSkipPassengers` | 小さいほど良い | 制御スキップ後に満員などでさらに乗れなかった人数です。悪い連鎖を見ます。 |
| 2 | 自発見送り人数 | `voluntaryDeferredPassengers` | 小さいほど良い | 混雑率可視化により自発的に後発便を選んだ人数です。制御スキップや満員通過とは別に見ます。 |
| 2 | 自発見送り発生回数 | `voluntaryDeferralEvents` | 小さいほど良い | 自発見送りが発生した停車回数です。 |
| 2 | 総自発見送り人数イベント | `totalVoluntaryDeferralPassengerEvents` | 小さいほど良い | 自発見送りの延べ人数です。同じ乗客が複数回見送った場合は複数回数えます。 |
| 2 | 自発見送り平均追加待ち | `voluntaryDeferralAvgExtraMin` | 小さいほど良い | 自発見送りした人の、初回見送りから実乗車までの平均時間です。 |
| 2 | 自発見送り最大追加待ち | `voluntaryDeferralMaxExtraMin` | 小さいほど良い | 自発見送りした人の、初回見送りから実乗車までの最大時間です。 |
| 2 | 平均総所要時間 | `avgTotalMin` | 小さいほど良い | 完了済み乗客だけの、発生から降車までの平均です。未完了者が多いrunでは補正指標を優先します。 |
| 2 | 上位5%総所要時間 | `top5TotalMin` | 小さいほど良い | 完了済み乗客だけの総所要時間95パーセンタイルです。 |
| 2 | 中央値待ち時間 | `medianWaitMin` | 小さいほど良い | 乗車できた乗客の典型的な待ち時間です。平均とのズレで偏りを見ます。 |
| 2 | 最大待ち時間 | `maxWaitMin` | 小さいほど良い | 乗車できた乗客の最大待ち時間です。外れ値に敏感なので補助確認向きです。 |
| 2 | 10分以上待ち人数 | `over10Min` | 小さいほど良い | 乗車できた乗客のうち、待ち時間が10分以上だった人数です。 |
| 2 | 車間標準偏差 | `headwayStdStops` | 小さいほど良い | 終了時点の車間ばらつきです。RMSEの補助指標です。 |
| 2 | 車間CV | `headwayCv` | 小さいほど良い | 車間標準偏差を平均車間で割った相対ばらつきです。 |
| 2 | 平均停留所占有率 | `avgStopOccupancyRate` | 小さいほど良い | 各停留所の有効停車可能台数に対する、バス停車延べ時間の利用率平均です。 |
| 2 | 総制御スキップ人数イベント | `totalControlSkipPassengerEvents` | 小さいほど良い | バス側から見た制御スキップ対象人数の延べ合計です。 |
| 2 | 最大スプリング保持秒 | `maxSpringHoldSec` | 小さいほど現実的 | 1回あたりの最大保持秒数です。現実運用上の許容性を見ます。 |
| 2 | 直近平均待ち時間 | `recentAvgWaitMin` | 小さいほど良い | 終了直前5分窓で乗車した人の平均待ち時間です。終盤悪化を見ます。 |
| 2 | 直近上位5%待ち時間 | `recentTop5WaitMin` | 小さいほど良い | 終了直前5分窓の待ち時間95パーセンタイルです。 |
| 1 | 団子度 | `bunchScore` | 小さいほど良い | 終了時点の車間CV、最小車間比、近接度から作る診断スコアです。 |
| 1 | 団子発生回数 | `bunchStarts` | 少ないほど良い | 期間中に団子状態へ入った回数です。 |
| 1 | 団子継続時間 | `bunchDurationMin` | 小さいほど良い | 期間中に団子状態だった累計時間です。 |
| 1 | 発生済み乗客数 | `allPassengers` | 条件確認用 | シミュレーション中に発生した全乗客数です。補正総所要時間の分母です。 |
| 1 | 乗車中人数 | `onboardNow` | 小さいほど良い | 終了時点でまだバスに乗っている人数です。 |
| 1 | 直近乗車人数 | `recentBoardedPassengers` | 多いほど信頼しやすい | 直近待ち時間指標のサンプル数です。少ない場合は直近指標を重く見ません。 |
| 1 | 理想車間 | `idealHeadwayStops` | 条件確認用 | 停留所数 ÷ バス台数で決まる基準車間です。 |
| 1 | 時刻 | `timeMin` | 評価対象外 | シミュレーション上の現在時刻です。 |
| 1 | 車間誤差二乗和 | `headwayErrorSum` | 小さいほど良い | RMSEの元になる車間誤差の二乗和です。通常はRMSEを見ます。 |
| 1 | 正/負スプリング信号平均 | `springPositiveSignalAvg` / `springNegativeSignalAvg` | 単独評価しない | spring制御がどちら向きに働きやすかったかの診断値です。 |
| 1 | スプリング信号絶対平均 | `springSignalAbsAvg` | 単独評価しない | spring信号の大きさの平均です。車間アンバランスの診断に使います。 |
| 1 | バス1台あたり前車待ち遅延 | `avgBlockedDelayPerBusMin` | 小さいほど良い | 前車待ち遅延累計をバス台数で割った値です。条件間比較の補助に使います。 |
| 1 | 最大前車待ち遅延 | `maxBlockedDelayMin` | 小さいほど良い | 1回の前車待ちで発生した最大遅延です。局所的な停留所詰まりを見ます。 |

## 補正総所要時間の定義

補正総所要時間は、終了時点でまだ降車完了していない乗客を評価から落とさないための比較用ペナルティ指標です。厳密な未来予測ではなく、方式間比較で未完了者が多い条件を甘く見ないために使います。

- 分母: シミュレーション中に発生済みの全乗客 `allPassengers`
- 完了済み乗客: `alightTime - arrivalTime`
- 乗車中乗客: `currentTime - arrivalTime + remainingStopsToDest * expectedStopToStopSec`
- 待機中乗客: `currentTime - arrivalTime + minBusArrivalToOriginSec + queuePenaltySec + tripStops * expectedStopToStopSec`

基準値は以下で計算します。

- `baseTravelSec = max(20, stopDistanceKm / max(4, baseSpeedKmh) * 3600)`
- `averageDwellSec = totalDwell / max(1, serviceStopCount)`
- `expectedStopToStopSec = baseTravelSec + randomDelayMeanSec + averageDwellSec`
- `idealHeadwaySec = (stopCount / busCount) * expectedStopToStopSec`
- `queuePenaltySec = max(0, waitingAtOrigin - capacity) / capacity * idealHeadwaySec`
- `minBusArrivalToOriginSec`: 全バスから乗車停留所までの推定到着時間の最小値

待機中乗客には、現在までの待ち時間、次のバス到着見込み、満員・長い待ち行列の簡易ペナルティ、乗車後の見込み移動時間を加えます。乗車中乗客には、現在までの経過時間と目的地までの残り区間見込みを加えます。

## 設定

実験設定JSONの主な項目です。

- `baseConfig`: 既存の `bus-bunching-config.json` と互換の基本設定
- `seeds`: `base`、`count`、`step` でseed列を指定
- `sweep`: `{ "param": "...", "min": ..., "max": ..., "points": ... }` の配列でスイープ対象を指定
- `modes`: 通常は `["plain", "skip", "spring"]`
- `history.aggregate`: 平均時系列を保存するかどうか
- `progress.intervalSec`: 進捗ファイルへ追記する最短間隔（秒）
- CLI `--engine`: `fast` は高速探索用、`audit` は検証用

広い範囲を探索するrunでは、まず `history.aggregate` を `false` にしてください。時系列履歴は便利ですが、シナリオ数が多いと生成・集計・保存が重くなります。候補を絞った最終確認runだけ `true` にするのがおすすめです。

例:

```json
{
  "sweep": [
    { "param": "springGainSecPerStop", "min": 20, "max": 60, "points": 3 },
    { "param": "springDeadbandStops", "min": 0.8, "max": 1.6, "points": 3 }
  ],
  "history": {
    "aggregate": false
  },
  "progress": {
    "intervalSec": 2
  }
}
```

`param` はプログラムが読む内部名です。`label` は省略できます。ダッシュボードやエクスポートでは既知の `param` に対して内蔵の日本語表示名を使います。

`min` と `max` は両端を含み、`points` 個の等間隔データ点に展開されます。上の例では `20, 40, 60` と `0.8, 1.2, 1.6` になり、合計 `3 × 3 = 9` シナリオを評価します。

個別の値を手で指定したい場合は、従来どおり `values` も使えます。

```json
{ "param": "springMaxHoldSec", "values": [60, 120, 180] }
```

複数パラメータを連動させたい場合は、`param` の代わりに `group` を使い、`values` にパラメータ辞書の配列を指定します。各辞書は同じパラメータ集合にしてください。下の例では `boardTimeSec` と `alightTimeSec` を1つの乗降処理プロファイルとして扱うため、シナリオ数は `4 × 5 = 20` です。

```json
{
  "sweep": [
    {
      "group": "dwellProcess",
      "values": [
        { "boardTimeSec": 2.0, "alightTimeSec": 2.0 },
        { "boardTimeSec": 3.0, "alightTimeSec": 3.0 },
        { "boardTimeSec": 4.0, "alightTimeSec": 4.0 },
        { "boardTimeSec": 5.0, "alightTimeSec": 5.0 }
      ]
    },
    {
      "param": "demandMultiplier",
      "values": [0.6, 0.8, 1.0, 1.2, 1.4]
    }
  ]
}
```

`group` の値はバックアップ・リネーム時の識別名に使われます。シミュレーション本体へ渡す設定値は、各辞書内の実パラメータ名へ展開されます。3変数以上を連動させる場合も同じ形式で、1つの辞書に `boardingSetupSec` などを追加できます。

## 主なパラメータ名

| 内部名 | 日本語名 |
| --- | --- |
| `durationMin` | シミュレーション時間（分） |
| `stopCount` | 停留所数 |
| `busCount` | バス台数 |
| `demandMultiplier` | 需要倍率 |
| `capacity` | バス定員 |
| `baseSpeedKmh` | 基本速度（km/h） |
| `stopDistanceKm` | 停留所間距離（km） |
| `boardTimeSec` | 乗車秒数（秒/人） |
| `alightTimeSec` | 降車秒数（秒/人） |
| `crowdedExtraSec` | 混雑時固定追加秒 |
| `fixedStopSec` | 停車固定秒 |
| `boardingSetupSec` | 乗車発生時固定秒 |
| `alightingSetupSec` | 降車発生時固定秒 |
| `crowdingThreshold` | 混雑判定しきい値 |
| `randomDelayMeanSec` | 区間平均遅れ（秒） |
| `hotspotStops` | 重要・集中停留所 |
| `protectHotspotStops` | 重要停留所スキップ禁止 |
| `hotspotMultiplier` | 集中停留所の需要倍率 |
| `stopBerthMode` | 複数台停車の適用範囲（`single` / `all` / `hotspot`） |
| `stopBerthCapacity` | 同時停車可能台数 |
| `initialDelaySec` | 初期遅延秒 |
| `distanceThresholdStops` | 後続車間しきい値（停留所） |
| `delayThresholdMin` | 先行遅延しきい値（分） |
| `followerLoadLimit` | 後続混雑率しきい値 |
| `springGainSecPerStop` | スプリングゲイン（秒/停留所） |
| `springDeadbandStops` | スプリング不感帯（停留所） |
| `springDamping` | スプリング遅延減衰 |
| `springMaxHoldSec` | 最大スプリング保持秒 |
| `springMinHoldSec` | 最小スプリング保持秒 |
| `springVoluntaryDeferralEnabled` | スプリング法で自発見送りを考慮 |
| `springControlSkipEnabled` | スプリング法で補助スキップを採用 |
| `springHoldingEnabled` | スプリング法で保持を採用 |
| `forbidHoldingWhenFull` | 満員時のスプリング保持禁止 |
