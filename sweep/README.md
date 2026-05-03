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

## 結果の見方

ダッシュボードでは、まず「地形図」を見ます。

- 地形図: ゲイン×不感帯などの探索空間を、青=良い / 赤=悪いのヒートマップで確認します。
- 候補ポートフォリオ: Pareto散布図と候補ランキングで、採用候補の位置づけを確認します。
- 方式差分: plain → skip → spring の変化をスロープ図と差分バーで確認します。
- リスク: 保持、スキップ、総所要悪化などの副作用分布を確認します。
- 詳細: 表、CSV出力、メタデータ、時系列を確認します。

- 補正平均総所要時間と補正上位5%総所要時間: 未完了乗客を評価から落とさない採用判断の主指標です。
- 平均待ち時間と上位5%待ち時間: 利用者が実感しやすい改善です。
- 平均総所要時間: 完了済み乗客だけで見た参考指標です。未完了者が多いrunでは補正総所要時間を優先します。
- 車間RMSEと最大車間: 運行が等間隔に近づいたかを見る主指標です。団子度は補助診断として確認します。
- スキップ人数と保持累計分: 改善の副作用です。大きい場合は採用候補から外すか、条件を弱めます。

基本的には、補正総所要時間・平均待ち時間・車間RMSEが同時に下がり、スキップ人数や保持累計分が過大でない候補を優先します。
団子度は直感的で便利ですが、車間RMSEがある場合は採用判断の主指標ではなく、候補の挙動を説明する補助指標として扱います。

## 主指標の選び方

採用判断でまず見る指標です。

| 指標 | 良い方向 | 使いどころ |
| --- | --- | --- |
| 補正平均総所要時間 | 小さいほど良い | 完了済み・乗車中・待機中の全発生乗客を人数分だけ評価に含める総合指標です。最優先で見ます。 |
| 補正上位5%総所要時間 | 小さいほど良い | 未完了者を含めた悪い側の総所要時間です。極端に不利な乗客が残っていないか見ます。 |
| 平均総所要時間 | 小さいほど良い | 完了済み乗客だけの総所要時間です。参考値として見ます。 |
| 平均待ち時間 | 小さいほど良い | 利用者が最も実感しやすい改善です。 |
| 上位5%待ち時間 | 小さいほど良い | 悪い側の待ち時間です。平均だけ改善して一部利用者が悪化していないか見ます。 |
| 車間RMSE | 小さいほど良い | 理想車間からのずれです。パラメータ選定では団子度より安定して比較しやすいです。 |
| 最大車間 | 小さいほど良い | 大きな空白区間が残っていないか確認します。 |
| 最小車間 | 大きいほど良い | 小さすぎるとバスが近接し、団子状態です。 |
| 団子度 | 小さいほど良い | 団子運転の総合スコアです。直感的な補助診断として使います。 |

副作用として必ず見る指標です。

| 指標 | 良い方向 | 使いどころ |
| --- | --- | --- |
| スキップ人数 | 小さいほど良い | 乗車を見送られた人数です。改善の代償として許容できるか判断します。 |
| スキップ平均追加待ち | 小さいほど良い | スキップ対象者の平均負担です。 |
| スキップ最大追加待ち | 小さいほど良い | スキップ対象者の最悪負担です。苦情リスクを見ます。 |
| 複数回スキップ人数 | 小さいほど良い | 同じ乗客が繰り返し不利益を受けていないか見ます。 |
| スキップ後満員影響人数 | 小さいほど良い | スキップされた後、後続にも乗れなかった人数です。特に避けたい副作用です。 |
| スプリング保持累計 | 過大なら悪い | バスを停留所に保持した総量です。待ち改善との釣り合いを見ます。 |
| 最大スプリング保持秒 | 小さいほど現実的 | 1回の保持が長すぎないか見ます。 |

補助的に見る指標です。

| 指標 | 良い方向 | 使いどころ |
| --- | --- | --- |
| 平均遅延 / 最大遅延 | 小さいほど良い | 運行側の遅れが増えすぎていないか確認します。 |
| 前車待ち遅延累計 | 小さいほど良い | バース1制約による停留所詰まりを見ます。 |
| 平均停留所占有率 | 小さいほど良い | 保持や停車が停留所を塞ぎすぎていないか見ます。 |
| 完了乗客数 | 多いほど良い | 時間内に目的地へ到着できた人数です。少ない候補は注意します。 |
| 発生済み乗客数 | 条件確認用 | 補正総所要時間の分母です。 |
| 乗車中人数 | 小さいほど良い | 終了時点でまだ降車していない人数です。補正総所要時間でペナルティ化されます。 |
| 待機中人数 | 小さいほど良い | 終了時点で未処理需要が残っていないか確認します。 |

診断用で、単独では採用判断に使わない指標です。

| 指標 | 見方 |
| --- | --- |
| 正/負スプリング信号平均 | スプリング制御がどちら向きに働いているかの診断用です。 |
| スプリング信号絶対平均 | 車間アンバランスの大きさを見る診断用です。 |

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
    { "param": "springGainSecPerStop", "label": "スプリングゲイン（秒/停留所）", "min": 20, "max": 60, "points": 3 },
    { "param": "springDeadbandStops", "label": "スプリング不感帯（停留所）", "min": 0.8, "max": 1.6, "points": 3 }
  ],
  "history": {
    "aggregate": false
  },
  "progress": {
    "intervalSec": 2
  }
}
```

`param` はプログラムが読む内部名です。`label` は人間向けの説明なので、分かりやすい日本語を書いて構いません。

`min` と `max` は両端を含み、`points` 個の等間隔データ点に展開されます。上の例では `20, 40, 60` と `0.8, 1.2, 1.6` になり、合計 `3 × 3 = 9` シナリオを評価します。

個別の値を手で指定したい場合は、従来どおり `values` も使えます。

```json
{ "param": "springMaxHoldSec", "label": "最大スプリング保持秒", "values": [60, 120, 180] }
```

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
| `stopManeuverLossSec` | 減速・加速ロス秒 |
| `doorTimeSec` | ドア開閉秒 |
| `boardingSetupSec` | 乗車発生時固定秒 |
| `alightingSetupSec` | 降車発生時固定秒 |
| `crowdingThreshold` | 混雑判定しきい値 |
| `randomDelayMeanSec` | 区間平均遅れ（秒） |
| `hotspotStops` | 重要・集中停留所 |
| `protectHotspotStops` | 重要停留所スキップ禁止 |
| `hotspotMultiplier` | 集中停留所の需要倍率 |
| `initialDelaySec` | 初期遅延秒 |
| `distanceThresholdStops` | 後続車間しきい値（停留所） |
| `delayThresholdMin` | 先行遅延しきい値（分） |
| `followerLoadLimit` | 後続混雑率しきい値 |
| `springGainSecPerStop` | スプリングゲイン（秒/停留所） |
| `springDeadbandStops` | スプリング不感帯（停留所） |
| `springDamping` | スプリング遅延減衰 |
| `springMaxHoldSec` | 最大スプリング保持秒 |
| `springMinHoldSec` | 最小スプリング保持秒 |
