from __future__ import annotations

import json
import html
import subprocess
import sys
from pathlib import Path

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
if str(PACKAGE_ROOT) not in sys.path:
    sys.path.insert(0, str(PACKAGE_ROOT))

from bus_sweep import derived as derived_data


def query_arg(name: str, default: str) -> str:
    args = sys.argv
    if f"--{name}" in args:
        i = args.index(f"--{name}")
        if i + 1 < len(args):
            return args[i + 1]
    return default


RUNS_ROOT = Path(query_arg("runs", "runs"))

METRIC_ORDER = [
    "adjustedAvgTotalMin",
    "adjustedTop5TotalMin",
    "avgTotalMin",
    "avgWaitMin",
    "top5WaitMin",
    "bunchScore",
    "headwayRmseStops",
    "maxHeadwayStops",
    "minHeadwayStops",
    "skippedPassengers",
    "skipAvgExtraMin",
    "skipMaxExtraMin",
    "multiSkippedPassengers",
    "deniedAfterSkip",
    "totalSpringHoldMin",
    "maxSpringHoldSec",
    "avgDelayMin",
    "maxDelayMin",
    "totalBlockedDelayMin",
    "avgStopOccupancyRate",
    "completed",
    "allPassengers",
    "onboardNow",
    "waitingNow",
    "top5TotalMin",
    "recentAvgWaitMin",
    "recentTop5WaitMin",
    "medianWaitMin",
    "maxWaitMin",
    "over10Min",
    "avgRideMin",
    "headwayStdStops",
    "headwayCv",
    "closePairs",
    "bunchStarts",
    "bunchDurationMin",
    "loadStd",
    "activeBlockedBuses",
    "avgBlockedDelayPerBusMin",
    "blockEvents",
    "avgBlockDurationMin",
    "maxBlockedDelayMin",
    "blockedDuringBunchMin",
    "totalStopOccupiedMin",
    "totalDwellMin",
    "skipEvents",
    "fullPassEvents",
    "uniqueDeniedFull",
    "springHoldEvents",
    "avgSpringHoldSec",
    "springSkipAssistEvents",
    "springInterventionCount",
    "springPositiveSignalAvg",
    "springNegativeSignalAvg",
    "springSignalAbsAvg",
    "recentBoardedPassengers",
    "headwayErrorSum",
    "totalSkips",
]

CATEGORY_STYLE = {
    "利用者": ("#dbeafe", "#1d4ed8"),
    "運行安定": ("#dcfce7", "#166534"),
    "副作用": ("#fee2e2", "#b91c1c"),
    "停留所容量": ("#fef3c7", "#92400e"),
    "制御負荷": ("#ede9fe", "#6d28d9"),
    "品質確認": ("#e5e7eb", "#374151"),
    "診断": ("#f3e8ff", "#7e22ce"),
    "その他": ("#f1f5f9", "#334155"),
}

EXCLUDED_PRIMARY_METRICS = {"idealHeadwayStops", "timeMin"}

KEY_COMPARISON_METRICS = [
    "adjustedAvgTotalMin",
    "adjustedTop5TotalMin",
    "avgTotalMin",
    "avgWaitMin",
    "top5WaitMin",
    "top5TotalMin",
    "headwayRmseStops",
    "maxHeadwayStops",
    "minHeadwayStops",
    "skippedPassengers",
    "skipAvgExtraMin",
    "skipMaxExtraMin",
    "totalSpringHoldMin",
    "maxSpringHoldSec",
    "avgDelayMin",
    "totalBlockedDelayMin",
    "completed",
    "bunchScore",
]

HIGHER_IS_BETTER = {"completed", "minHeadwayStops", "recentBoardedPassengers"}
LOWER_IS_BETTER = {
    "adjustedAvgTotalMin",
    "adjustedTop5TotalMin",
    "avgWaitMin",
    "top5WaitMin",
    "avgTotalMin",
    "top5TotalMin",
    "bunchScore",
    "headwayRmseStops",
    "maxHeadwayStops",
    "skippedPassengers",
    "skipAvgExtraMin",
    "skipMaxExtraMin",
    "multiSkippedPassengers",
    "deniedAfterSkip",
    "totalSpringHoldMin",
    "maxSpringHoldSec",
    "avgDelayMin",
    "maxDelayMin",
    "totalBlockedDelayMin",
    "avgStopOccupancyRate",
    "waitingNow",
}

DECISION_WEIGHTS = {
    "adjustedAvgTotalMin": 0.30,
    "avgWaitMin": 0.25,
    "top5WaitMin": 0.15,
    "headwayRmseStops": 0.20,
    "maxHeadwayStops": 0.10,
}

CANDIDATE_DISPLAY_COLUMNS = [
    "判定",
    "順位",
    "総合点",
    "スプリングゲイン",
    "スプリング不感帯",
    "補正平均総所要時間",
    "制御なし比 補正総所要改善",
    "skip比 補正総所要改善",
    "補正上位5%総所要時間",
    "平均総所要時間",
    "制御なし比 総所要改善",
    "skip比 総所要改善",
    "平均待ち時間",
    "制御なし比 待ち改善",
    "skip比 待ち改善",
    "車間RMSE",
    "制御なし比 RMSE改善",
    "skip比 RMSE改善",
    "最大車間",
    "スキップ人数",
    "保持累計分",
    "最大保持秒",
    "注意理由",
]

MODE_LABELS = {
    "plain": "制御なし",
    "skip": "スキップ制御",
    "spring": "スプリング法",
}

METRIC_LABELS = {
    "activeBlockedBuses": "前車待ち中バス数",
    "avgBlockDurationMin": "平均前車待ち時間",
    "avgBlockedDelayPerBusMin": "バス1台あたり前車待ち遅延",
    "avgDelayMin": "平均遅延",
    "avgRideMin": "平均乗車時間",
    "avgSpringHoldSec": "平均スプリング保持秒",
    "avgStopOccupancyRate": "平均停留所占有率",
    "adjustedAvgTotalMin": "補正平均総所要時間",
    "adjustedTop5TotalMin": "補正上位5%総所要時間",
    "avgTotalMin": "平均総所要時間",
    "avgWaitMin": "平均待ち時間",
    "blockEvents": "前車待ち発生回数",
    "blockedDuringBunchMin": "団子中の前車待ち時間",
    "bunchDurationMin": "団子継続時間",
    "bunchScore": "団子度",
    "bunchStarts": "団子発生回数",
    "closePairs": "近接ペア数",
    "completed": "完了乗客数",
    "allPassengers": "発生済み乗客数",
    "onboardNow": "乗車中人数",
    "deniedAfterSkip": "スキップ後満員影響人数",
    "fullPassEvents": "満員通過回数",
    "headwayCv": "車間CV",
    "headwayErrorSum": "車間誤差二乗和",
    "headwayRmseStops": "車間RMSE",
    "headwayStdStops": "車間標準偏差",
    "idealHeadwayStops": "理想車間",
    "loadStd": "乗車人数標準偏差",
    "maxBlockedDelayMin": "最大前車待ち遅延",
    "maxDelayMin": "最大遅延",
    "maxHeadwayStops": "最大車間",
    "maxSpringHoldSec": "最大スプリング保持秒",
    "maxWaitMin": "最大待ち時間",
    "medianWaitMin": "中央値待ち時間",
    "minHeadwayStops": "最小車間",
    "multiSkippedPassengers": "複数回スキップ人数",
    "over10Min": "10分以上待ち人数",
    "top5TotalMin": "上位5%総所要時間",
    "top5WaitMin": "上位5%待ち時間",
    "recentAvgWaitMin": "直近平均待ち時間",
    "recentBoardedPassengers": "直近乗車人数",
    "recentTop5WaitMin": "直近上位5%待ち時間",
    "skipAvgExtraMin": "スキップ平均追加待ち",
    "skipEvents": "スキップ回数",
    "skipMaxExtraMin": "スキップ最大追加待ち",
    "skippedPassengers": "スキップ人数",
    "springHoldEvents": "スプリング保持回数",
    "springInterventionCount": "スプリング介入回数",
    "springNegativeSignalAvg": "負スプリング信号平均",
    "springPositiveSignalAvg": "正スプリング信号平均",
    "springSignalAbsAvg": "スプリング信号絶対平均",
    "springSkipAssistEvents": "補助スキップ回数",
    "timeMin": "時刻",
    "totalBlockedDelayMin": "前車待ち遅延累計",
    "totalDwellMin": "停車時間累計",
    "totalSkips": "総スキップ数",
    "totalSpringHoldMin": "スプリング保持累計",
    "totalStopOccupiedMin": "停留所占有累計",
    "uniqueDeniedFull": "満員影響人数",
    "waitingNow": "待機中人数",
    "expectedStopToStopSec": "推定1停留所移動秒",
    "averageDwellSec": "平均停車秒",
    "serviceStopCount": "停車処理回数",
}

METRIC_GUIDE = {
    "adjustedAvgTotalMin": ("利用者", "小さいほど良い", "完了済み・乗車中・待機中の全発生乗客を人数分だけ含めた補正総所要時間。未完了者が多い方式を甘く評価しないための主指標。"),
    "adjustedTop5TotalMin": ("利用者", "小さいほど良い", "補正総所要時間の悪い側。未完了者を含めた利用者リスクを見る。"),
    "avgWaitMin": ("利用者", "小さいほど良い", "平均的な待ち時間。まず見る主指標。"),
    "top5WaitMin": ("利用者", "小さいほど良い", "待ち時間の悪い側。公平性や苦情リスクを見る。"),
    "recentAvgWaitMin": ("利用者", "小さいほど良い", "終了直前5分の平均待ち時間。後半に悪化していないかを見る。"),
    "recentTop5WaitMin": ("利用者", "小さいほど良い", "終了直前5分の悪い側の待ち時間。終盤の不安定化を見る。"),
    "recentBoardedPassengers": ("品質確認", "多いほど信頼しやすい", "直近待ち時間のサンプル数。少ない場合は直近指標を重く見ない。"),
    "medianWaitMin": ("利用者", "小さいほど良い", "典型的な乗客の待ち時間。平均とのズレで偏りを見る。"),
    "maxWaitMin": ("利用者", "小さいほど良い", "最悪待ち時間。外れ値に敏感なので補助指標。"),
    "over10Min": ("利用者", "小さいほど良い", "10分以上待った人数。サービス水準の閾値管理に使う。"),
    "avgRideMin": ("利用者", "小さいほど良い", "乗車後の平均移動時間。保持や前車待ちの車内影響を見る。"),
    "avgTotalMin": ("利用者", "小さいほど良い", "待ち始めから降車までの総所要時間。完了済み乗客だけで集計するため、未完了者が多いケースでは補正総所要時間を優先する。"),
    "top5TotalMin": ("利用者", "小さいほど良い", "総所要時間の悪い側。利用者体験の悪化を確認する。"),
    "bunchScore": ("診断", "小さいほど良い", "団子運転の総合スコア。車間RMSEを主指標にしたうえで、直感的な補助確認に使う。"),
    "headwayRmseStops": ("運行安定", "小さいほど良い", "理想車間からのズレ。制御パラメータ選定で重視。"),
    "minHeadwayStops": ("運行安定", "大きいほど良い", "最も近い車間。小さすぎると団子。"),
    "maxHeadwayStops": ("運行安定", "小さいほど良い", "最大空白区間。大きいほど待ちの偏りが出やすい。"),
    "headwayStdStops": ("運行安定", "小さいほど良い", "車間のばらつき。RMSEより素朴な分散指標。"),
    "headwayCv": ("運行安定", "小さいほど良い", "平均車間に対する相対ばらつき。条件比較に使う。"),
    "closePairs": ("運行安定", "小さいほど良い", "1停留所以内に近接したペア数。団子の直接検知。"),
    "bunchStarts": ("運行安定", "少ないほど良い", "団子発生回数。細かく発生と解消を繰り返す場合に増える。"),
    "bunchDurationMin": ("運行安定", "小さいほど良い", "団子状態の継続時間。運行の回復力を見る。"),
    "avgDelayMin": ("運行安定", "小さいほど良い", "バスの平均遅延。保持で悪化しすぎないか確認。"),
    "maxDelayMin": ("運行安定", "小さいほど良い", "最大遅延。極端に遅れるバスの有無を見る。"),
    "loadStd": ("運行安定", "小さいほど良い", "バス間の乗車人数ばらつき。混雑の偏りを見る。"),
    "activeBlockedBuses": ("停留所容量", "小さいほど良い", "前車待ち中のバス数。停留所詰まりを見る。"),
    "totalBlockedDelayMin": ("停留所容量", "小さいほど良い", "前車待ち遅延の累計。バース1制約の悪化を見る。"),
    "avgBlockedDelayPerBusMin": ("停留所容量", "小さいほど良い", "バス1台あたり前車待ち遅延。条件間比較向き。"),
    "blockEvents": ("停留所容量", "小さいほど良い", "前車待ち発生回数。詰まり頻度を見る。"),
    "avgBlockDurationMin": ("停留所容量", "小さいほど良い", "1回あたり前車待ち時間。詰まりの深刻度を見る。"),
    "maxBlockedDelayMin": ("停留所容量", "小さいほど良い", "最大前車待ち遅延。局所的な破綻を見る。"),
    "blockedDuringBunchMin": ("停留所容量", "小さいほど良い", "団子状態中の前車待ち。団子と停留所詰まりの連動を見る。"),
    "avgStopOccupancyRate": ("停留所容量", "小さいほど良い", "停留所が占有されている割合。保持が停留所を塞がないか確認。"),
    "totalStopOccupiedMin": ("停留所容量", "小さいほど良い", "停留所占有時間の累計。停留所負荷の総量。"),
    "totalDwellMin": ("停留所容量", "小さいほど良い", "全バスの停車時間累計。需要処理・保持の重さを見る。"),
    "skippedPassengers": ("副作用", "小さいほど良い", "スキップで乗車を見送られた人数。利用者負担の代表指標。"),
    "skipEvents": ("副作用", "小さいほど良い", "スキップ発動回数。施策の介入頻度。"),
    "skipAvgExtraMin": ("副作用", "小さいほど良い", "スキップ対象者の平均追加待ち。公平性で重要。"),
    "skipMaxExtraMin": ("副作用", "小さいほど良い", "スキップ対象者の最大追加待ち。苦情リスクを見る。"),
    "multiSkippedPassengers": ("副作用", "小さいほど良い", "複数回スキップされた人数。避けたい副作用。"),
    "deniedAfterSkip": ("副作用", "小さいほど良い", "スキップ後に満員で乗れなかった人数。かなり悪い副作用。"),
    "fullPassEvents": ("副作用", "小さいほど良い", "満員通過回数。容量不足の兆候。"),
    "uniqueDeniedFull": ("副作用", "小さいほど良い", "満員の影響を受けた人数。容量不足の利用者影響。"),
    "springHoldEvents": ("制御負荷", "少ないほど良いとは限らない", "スプリング保持回数。介入量の把握に使う。"),
    "totalSpringHoldMin": ("制御負荷", "過大なら悪い", "スプリング保持累計。待ち改善との釣り合いを見る。"),
    "avgSpringHoldSec": ("制御負荷", "過大なら悪い", "1回あたり平均保持秒。現実運用しやすさを見る。"),
    "maxSpringHoldSec": ("制御負荷", "小さいほど現実的", "最大保持秒。乗客・運転士が許容できるか確認。"),
    "springSkipAssistEvents": ("制御負荷", "小さいほど説明しやすい", "スプリング補助スキップ回数。副作用と合わせて見る。"),
    "springInterventionCount": ("制御負荷", "少ないほど説明しやすい", "保持と補助スキップの合計介入回数。"),
    "springPositiveSignalAvg": ("診断", "単独評価しない", "前が空き後ろが近い信号の平均。制御挙動の診断用。"),
    "springNegativeSignalAvg": ("診断", "単独評価しない", "前が近く後ろが空く信号の平均。保持判断の診断用。"),
    "springSignalAbsAvg": ("診断", "小さいほど均衡", "スプリング信号の絶対平均。車間アンバランスの診断。"),
    "completed": ("品質確認", "多いほど良い", "時間内に目的地へ到着した乗客数。少ない候補は注意。"),
    "allPassengers": ("品質確認", "条件確認用", "シミュレーション中に発生済みの全乗客数。補正総所要時間の分母。"),
    "onboardNow": ("品質確認", "小さいほど良い", "終了時点で乗車中の人数。未完了需要の残り。"),
    "waitingNow": ("品質確認", "小さいほど良い", "終了時点で待っている人数。未処理需要の残り。"),
    "timeMin": ("品質確認", "評価対象外", "シミュレーション上の現在時刻。主指標には通常使わない。"),
    "idealHeadwayStops": ("品質確認", "評価対象外", "理想車間。条件確認用で、最適化対象ではない。"),
    "headwayErrorSum": ("運行安定", "小さいほど良い", "車間誤差の二乗和。RMSEの元になる指標。"),
    "totalSkips": ("副作用", "小さいほど良い", "バス側から見た総スキップ数。skippedPassengersと合わせて見る。"),
}

PARAM_LABELS = {
    "name": "設定名",
    "seed": "乱数シード",
    "durationMin": "シミュレーション時間（分）",
    "stopCount": "停留所数",
    "busCount": "バス台数",
    "demandMultiplier": "需要倍率",
    "capacity": "バス定員",
    "baseSpeedKmh": "基本速度（km/h）",
    "stopDistanceKm": "停留所間距離（km）",
    "boardTimeSec": "乗車秒数（秒/人）",
    "alightTimeSec": "降車秒数（秒/人）",
    "crowdedExtraSec": "混雑時固定追加秒",
    "stopManeuverLossSec": "減速・加速ロス秒",
    "doorTimeSec": "ドア開閉秒",
    "boardingSetupSec": "乗車発生時固定秒",
    "alightingSetupSec": "降車発生時固定秒",
    "crowdingThreshold": "混雑判定しきい値",
    "randomDelayMeanSec": "区間平均遅れ（秒）",
    "hotspotStops": "重要・集中停留所",
    "protectHotspotStops": "重要停留所スキップ禁止",
    "hotspotMultiplier": "集中停留所の需要倍率",
    "initialDelaySec": "初期遅延秒",
    "distanceThresholdStops": "後続車間しきい値（停留所）",
    "delayThresholdMin": "先行遅延しきい値（分）",
    "followerLoadLimit": "後続混雑率しきい値",
    "springGainSecPerStop": "スプリングゲイン（秒/停留所）",
    "springDeadbandStops": "スプリング不感帯（停留所）",
    "springDamping": "スプリング遅延減衰",
    "springMaxHoldSec": "最大スプリング保持秒",
    "springMinHoldSec": "最小スプリング保持秒",
}

COLUMN_LABELS = {
    "scenario_id": "シナリオ",
    "mode": "方式",
    "metric": "指標",
    "mean": "平均",
    "sd": "標準偏差",
    "n": "件数",
    "t": "時刻秒",
    "seed": "seed",
}


def param_label(param: str) -> str:
    return PARAM_LABELS.get(param, param)


def metric_label(metric: str) -> str:
    return METRIC_LABELS.get(metric, metric)


def metric_select_label(metric: str) -> str:
    category, _, _ = METRIC_GUIDE.get(metric, ("その他", "", ""))
    return f"[{category}] {metric_label(metric)}"


def sorted_metrics(metrics: list[str]) -> list[str]:
    order = {metric: i for i, metric in enumerate(METRIC_ORDER)}
    return sorted(
        [metric for metric in metrics if metric not in EXCLUDED_PRIMARY_METRICS],
        key=lambda metric: (order.get(metric, 10_000), metric_label(metric)),
    )


def metric_ascending(metric: str) -> bool:
    if metric in HIGHER_IS_BETTER:
        return False
    return True


def metric_direction(metric: str) -> int:
    return 1 if metric in HIGHER_IS_BETTER else -1


def mode_label(mode: str) -> str:
    return MODE_LABELS.get(mode, mode)


def metric_guide_table() -> pd.DataFrame:
    rows = []
    for metric in sorted_metrics(list(METRIC_LABELS)):
        label = METRIC_LABELS[metric]
        category, direction, explanation = METRIC_GUIDE.get(metric, ("その他", "文脈による", "追加指標です。"))
        rows.append({"指標": label, "内部名": metric, "分類": category, "良い方向": direction, "説明": explanation})
    return pd.DataFrame(rows)


def metric_guide_html() -> str:
    rows = []
    for row in metric_guide_table().to_dict("records"):
        bg, fg = CATEGORY_STYLE.get(row["分類"], CATEGORY_STYLE["その他"])
        rows.append(
            "<tr>"
            f"<td>{html.escape(row['指標'])}</td>"
            f"<td><code>{html.escape(row['内部名'])}</code></td>"
            f"<td><span style='display:inline-block;border-radius:4px;padding:2px 8px;background:{bg};color:{fg};font-weight:600'>{html.escape(row['分類'])}</span></td>"
            f"<td>{html.escape(row['良い方向'])}</td>"
            f"<td>{html.escape(row['説明'])}</td>"
            "</tr>"
        )
    return (
        "<table style='width:100%;border-collapse:collapse'>"
        "<thead><tr><th style='text-align:left'>指標</th><th style='text-align:left'>内部名</th><th style='text-align:left'>分類</th><th style='text-align:left'>良い方向</th><th style='text-align:left'>説明</th></tr></thead>"
        "<tbody>"
        + "".join(rows)
        + "</tbody></table>"
    )


def display_table(df: pd.DataFrame) -> pd.DataFrame:
    shown = df.copy()
    if "mode" in shown:
        shown["mode"] = shown["mode"].map(mode_label)
    if "metric" in shown:
        shown["metric"] = shown["metric"].map(metric_label)
    return shown.rename(columns={**COLUMN_LABELS, **PARAM_LABELS})


def scenario_label(row: pd.Series | dict) -> str:
    params = []
    for key in PARAM_LABELS:
        if key in row and pd.notna(row[key]):
            params.append(f"{param_label(key)}={row[key]}")
    return " / ".join(params) if params else str(row.get("scenario_id", "base"))


def build_decision_table(aggregate_df: pd.DataFrame) -> pd.DataFrame:
    metric_means = aggregate_df.pivot_table(index=["scenario_id", "mode"], columns="metric", values="mean", aggfunc="mean").reset_index()
    params = aggregate_df.drop_duplicates("scenario_id")[
        ["scenario_id", *[c for c in aggregate_df.columns if c not in {"scenario_id", "mode", "metric", "mean", "sd", "n"}]]
    ]
    table = metric_means.merge(params, on="scenario_id", how="left")
    rows = []
    lower_is_better = [
        "adjustedAvgTotalMin",
        "adjustedTop5TotalMin",
        "avgWaitMin",
        "top5WaitMin",
        "avgTotalMin",
        "top5TotalMin",
        "bunchScore",
        "headwayRmseStops",
        "maxHeadwayStops",
        "totalBlockedDelayMin",
    ]
    for scenario_id, group in table.groupby("scenario_id"):
        plain_rows = group[group["mode"].eq("plain")]
        if plain_rows.empty:
            continue
        plain = plain_rows.iloc[0]
        for _, row in group[~group["mode"].eq("plain")].iterrows():
            out = row.to_dict()
            for metric in lower_is_better:
                base = plain.get(metric)
                value = row.get(metric)
                if pd.notna(base) and pd.notna(value) and base != 0:
                    out[f"{metric}_improvement_pct"] = (base - value) / base * 100
            out["completed_delta"] = row.get("completed", 0) - plain.get("completed", 0)
            out["scenario_label"] = scenario_label(row)
            out["mode_label"] = mode_label(str(row["mode"]))
            out["decision_score"] = (
                out.get("adjustedAvgTotalMin_improvement_pct", 0) * 0.30
                + out.get("avgWaitMin_improvement_pct", 0) * 0.25
                + out.get("top5WaitMin_improvement_pct", 0) * 0.15
                + out.get("headwayRmseStops_improvement_pct", 0) * 0.20
                + out.get("maxHeadwayStops_improvement_pct", 0) * 0.10
            )
            rows.append(out)
    return pd.DataFrame(rows).sort_values("decision_score", ascending=False) if rows else pd.DataFrame()


def fmt_pct(value: float | int | None) -> str:
    if value is None or pd.isna(value):
        return "-"
    sign = "+" if value > 0 else ""
    return f"{sign}{value:.1f}%"


def fmt_num(value: float | int | None, digits: int = 2) -> str:
    if value is None or pd.isna(value):
        return "-"
    return f"{value:.{digits}f}"


def decision_display(df: pd.DataFrame) -> pd.DataFrame:
    cols = [
        "scenario_label",
        "mode_label",
        "decision_score",
        "adjustedAvgTotalMin",
        "adjustedAvgTotalMin_improvement_pct",
        "adjustedTop5TotalMin",
        "adjustedTop5TotalMin_improvement_pct",
        "avgWaitMin",
        "avgWaitMin_improvement_pct",
        "avgTotalMin",
        "avgTotalMin_improvement_pct",
        "headwayRmseStops",
        "headwayRmseStops_improvement_pct",
        "top5WaitMin",
        "top5WaitMin_improvement_pct",
        "top5TotalMin",
        "top5TotalMin_improvement_pct",
        "maxHeadwayStops",
        "maxHeadwayStops_improvement_pct",
        "skippedPassengers",
        "skipAvgExtraMin",
        "totalSpringHoldMin",
        "maxSpringHoldSec",
        "avgDelayMin",
        "completed_delta",
        "bunchScore",
        "bunchScore_improvement_pct",
    ]
    existing = [c for c in cols if c in df.columns]
    shown = df[existing].copy()
    rename = {
        "scenario_label": "条件",
        "mode_label": "方式",
        "decision_score": "総合スコア",
        "adjustedAvgTotalMin": "補正平均総所要時間",
        "adjustedAvgTotalMin_improvement_pct": "補正総所要改善率",
        "adjustedTop5TotalMin": "補正上位5%総所要時間",
        "adjustedTop5TotalMin_improvement_pct": "補正上位5%総所要改善率",
        "avgWaitMin": "平均待ち時間",
        "avgWaitMin_improvement_pct": "平均待ち改善率",
        "avgTotalMin": "平均総所要時間",
        "avgTotalMin_improvement_pct": "総所要改善率",
        "headwayRmseStops": "車間RMSE",
        "headwayRmseStops_improvement_pct": "車間RMSE改善率",
        "top5WaitMin": "上位5%待ち時間",
        "top5WaitMin_improvement_pct": "上位5%待ち改善率",
        "top5TotalMin": "上位5%総所要時間",
        "top5TotalMin_improvement_pct": "上位5%総所要改善率",
        "maxHeadwayStops": "最大車間",
        "maxHeadwayStops_improvement_pct": "最大車間改善率",
        "skippedPassengers": "スキップ人数",
        "skipAvgExtraMin": "スキップ平均追加待ち",
        "totalSpringHoldMin": "保持累計分",
        "maxSpringHoldSec": "最大保持秒",
        "avgDelayMin": "平均遅延",
        "completed_delta": "完了乗客差",
        "bunchScore": "団子度（参考）",
        "bunchScore_improvement_pct": "団子度改善率（参考）",
    }
    return shown.rename(columns=rename)


def format_decision_table(df: pd.DataFrame) -> pd.DataFrame:
    shown = df.copy()
    formats = {
        "総合スコア": "{:.1f}",
        "補正平均総所要時間": "{:.2f}",
        "補正総所要改善率": "{:+.1f}%",
        "補正上位5%総所要時間": "{:.2f}",
        "補正上位5%総所要改善率": "{:+.1f}%",
        "平均待ち時間": "{:.2f}",
        "平均待ち改善率": "{:+.1f}%",
        "平均総所要時間": "{:.2f}",
        "総所要改善率": "{:+.1f}%",
        "団子度": "{:.1f}",
        "団子度改善率": "{:+.1f}%",
        "車間RMSE": "{:.2f}",
        "車間RMSE改善率": "{:+.1f}%",
        "上位5%総所要時間": "{:.2f}",
        "上位5%総所要改善率": "{:+.1f}%",
        "最大車間": "{:.2f}",
        "最大車間改善率": "{:+.1f}%",
        "上位5%待ち時間": "{:.2f}",
        "上位5%待ち改善率": "{:+.1f}%",
        "スキップ人数": "{:.1f}",
        "スキップ平均追加待ち": "{:.2f}",
        "保持累計分": "{:.1f}",
        "最大保持秒": "{:.1f}",
        "平均遅延": "{:.2f}",
        "完了乗客差": "{:+.1f}",
        "団子度（参考）": "{:.1f}",
        "団子度改善率（参考）": "{:+.1f}%",
    }
    for column, fmt in formats.items():
        if column in shown.columns:
            shown[column] = shown[column].map(lambda value, fmt=fmt: "-" if pd.isna(value) else fmt.format(value))
    return shown


def comparison_for_scenario(aggregate_df: pd.DataFrame, scenario_id: str) -> pd.DataFrame:
    rows = aggregate_df[
        aggregate_df["scenario_id"].eq(scenario_id)
        & aggregate_df["metric"].isin(KEY_COMPARISON_METRICS)
    ]
    if rows.empty:
        return pd.DataFrame()
    wide = rows.pivot_table(index="metric", columns="mode", values="mean", aggfunc="mean").reset_index()
    wide["sort_key"] = wide["metric"].map({metric: i for i, metric in enumerate(KEY_COMPARISON_METRICS)})
    wide = wide.sort_values("sort_key").drop(columns="sort_key")

    display = pd.DataFrame()
    display["分類"] = wide["metric"].map(lambda metric: METRIC_GUIDE.get(metric, ("その他", "", ""))[0])
    display["指標"] = wide["metric"].map(metric_label)
    for mode_name in ["plain", "skip", "spring"]:
        if mode_name in wide:
            display[mode_label(mode_name)] = wide[mode_name]

    if "plain" in wide and "spring" in wide:
        display["spring改善率 vs 制御なし"] = [
            improvement_pct(metric, spring, plain)
            for metric, spring, plain in zip(wide["metric"], wide["spring"], wide["plain"])
        ]
    if "skip" in wide and "spring" in wide:
        display["spring改善率 vs スキップ"] = [
            improvement_pct(metric, spring, skip)
            for metric, spring, skip in zip(wide["metric"], wide["spring"], wide["skip"])
        ]
    return display


def improvement_pct(metric: str, value: float, base: float) -> float | None:
    if pd.isna(value) or pd.isna(base) or base == 0:
        return None
    if metric in HIGHER_IS_BETTER:
        return (value - base) / base * 100
    return (base - value) / base * 100


def format_comparison_table(df: pd.DataFrame) -> pd.DataFrame:
    shown = df.copy()
    value_columns = [mode_label(mode) for mode in ["plain", "skip", "spring"] if mode_label(mode) in shown.columns]
    for column in value_columns:
        shown[column] = shown[column].map(lambda value: "-" if pd.isna(value) else f"{value:.2f}")
    for column in ["spring改善率 vs 制御なし", "spring改善率 vs スキップ"]:
        if column in shown:
            shown[column] = shown[column].map(fmt_pct)
    return shown


def build_candidate_table(aggregate_df: pd.DataFrame) -> pd.DataFrame:
    metric_wide = aggregate_df.pivot_table(
        index=["scenario_id", "mode"],
        columns="metric",
        values="mean",
        aggfunc="mean",
    ).reset_index()
    param_cols = [
        c
        for c in aggregate_df.columns
        if c not in {"scenario_id", "mode", "metric", "mean", "sd", "n"}
    ]
    params = aggregate_df.drop_duplicates("scenario_id")[["scenario_id", *param_cols]]
    metric_wide = metric_wide.merge(params, on="scenario_id", how="left")

    rows = []
    for scenario_id, group in metric_wide.groupby("scenario_id", sort=False):
        by_mode = {str(row["mode"]): row for _, row in group.iterrows()}
        if "spring" not in by_mode:
            continue
        spring = by_mode["spring"]
        plain = by_mode.get("plain")
        skip = by_mode.get("skip")

        score = 0.0
        for metric, weight in DECISION_WEIGHTS.items():
            base = plain.get(metric) if plain is not None else None
            value = spring.get(metric)
            imp = improvement_pct(metric, value, base)
            if imp is not None:
                score += imp * weight

        warnings: list[str] = []
        strong_warnings: list[str] = []
        if skip is not None and pd.notna(spring.get("adjustedAvgTotalMin")) and pd.notna(skip.get("adjustedAvgTotalMin")):
            if spring.get("adjustedAvgTotalMin") > skip.get("adjustedAvgTotalMin"):
                warnings.append("補正平均総所要がskipより悪化")
        if plain is not None and pd.notna(spring.get("adjustedTop5TotalMin")) and pd.notna(plain.get("adjustedTop5TotalMin")):
            if spring.get("adjustedTop5TotalMin") > plain.get("adjustedTop5TotalMin"):
                strong_warnings.append("補正上位5%総所要が制御なしより悪化")
        if pd.notna(spring.get("maxSpringHoldSec")) and spring.get("maxSpringHoldSec") > 120:
            warnings.append("最大保持120秒超")
        if pd.notna(spring.get("totalSpringHoldMin")) and spring.get("totalSpringHoldMin") > 60:
            warnings.append("保持累計60分超")
        if skip is not None and pd.notna(spring.get("skippedPassengers")) and pd.notna(skip.get("skippedPassengers")):
            if spring.get("skippedPassengers") > skip.get("skippedPassengers") * 0.5:
                warnings.append("スキップ人数がskipの50%超")

        if strong_warnings:
            verdict = "除外候補"
        elif len(warnings) >= 2:
            verdict = "保留"
        elif warnings:
            verdict = "注意"
        else:
            verdict = "推奨"

        out = spring.to_dict()
        out.update(
            {
                "scenario_label": scenario_label(spring),
                "総合点": score,
                "判定": verdict,
                "注意理由": " / ".join([*strong_warnings, *warnings]) if strong_warnings or warnings else "なし",
                "adjustedAvgTotal_vs_skip_pct": improvement_pct("adjustedAvgTotalMin", spring.get("adjustedAvgTotalMin"), skip.get("adjustedAvgTotalMin") if skip is not None else None),
                "adjustedAvgTotal_vs_plain_pct": improvement_pct("adjustedAvgTotalMin", spring.get("adjustedAvgTotalMin"), plain.get("adjustedAvgTotalMin") if plain is not None else None),
                "adjustedTop5Total_vs_skip_pct": improvement_pct("adjustedTop5TotalMin", spring.get("adjustedTop5TotalMin"), skip.get("adjustedTop5TotalMin") if skip is not None else None),
                "adjustedTop5Total_vs_plain_pct": improvement_pct("adjustedTop5TotalMin", spring.get("adjustedTop5TotalMin"), plain.get("adjustedTop5TotalMin") if plain is not None else None),
                "avgTotal_vs_skip_pct": improvement_pct("avgTotalMin", spring.get("avgTotalMin"), skip.get("avgTotalMin") if skip is not None else None),
                "avgWait_vs_skip_pct": improvement_pct("avgWaitMin", spring.get("avgWaitMin"), skip.get("avgWaitMin") if skip is not None else None),
                "headwayRmse_vs_skip_pct": improvement_pct("headwayRmseStops", spring.get("headwayRmseStops"), skip.get("headwayRmseStops") if skip is not None else None),
                "avgTotal_vs_plain_pct": improvement_pct("avgTotalMin", spring.get("avgTotalMin"), plain.get("avgTotalMin") if plain is not None else None),
                "avgWait_vs_plain_pct": improvement_pct("avgWaitMin", spring.get("avgWaitMin"), plain.get("avgWaitMin") if plain is not None else None),
                "headwayRmse_vs_plain_pct": improvement_pct("headwayRmseStops", spring.get("headwayRmseStops"), plain.get("headwayRmseStops") if plain is not None else None),
            }
        )
        rows.append(out)

    if not rows:
        return pd.DataFrame()
    candidates = pd.DataFrame(rows).sort_values("総合点", ascending=False).reset_index(drop=True)
    candidates["順位"] = candidates.index + 1
    return candidates


def build_mode_comparison(aggregate_df: pd.DataFrame, scenario_id: str) -> pd.DataFrame:
    comparison = comparison_for_scenario(aggregate_df, scenario_id)
    if comparison.empty:
        return comparison
    comparison["判定"] = comparison["spring改善率 vs スキップ"].map(
        lambda value: "改善" if pd.notna(value) and value > 0.5 else ("悪化" if pd.notna(value) and value < -0.5 else "同等")
    )
    cols = ["分類", "指標", "制御なし", "スキップ制御", "スプリング法", "spring改善率 vs 制御なし", "spring改善率 vs スキップ", "判定"]
    return comparison[[c for c in cols if c in comparison.columns]]


def build_candidate_notes(candidate: pd.Series) -> list[str]:
    notes = []
    if candidate.get("判定") == "推奨":
        notes.append("制約違反がなく、採用候補として最初に確認できます。")
    elif candidate.get("判定") == "除外候補":
        notes.append("強い注意条件に該当します。採用よりも再スイープ範囲の参考として扱います。")
    else:
        notes.append(f"{candidate.get('判定')}です。注意理由: {candidate.get('注意理由')}")

    total_skip = candidate.get("adjustedAvgTotal_vs_skip_pct")
    wait_skip = candidate.get("avgWait_vs_skip_pct")
    rmse_skip = candidate.get("headwayRmse_vs_skip_pct")
    hold = candidate.get("totalSpringHoldMin")
    if pd.notna(total_skip):
        notes.append(f"skip比の補正総所要時間改善は {fmt_pct(total_skip)} です。")
    if pd.notna(wait_skip) and pd.notna(rmse_skip):
        notes.append(f"待ち時間は {fmt_pct(wait_skip)}、車間RMSEは {fmt_pct(rmse_skip)} 改善しています。")
    if pd.notna(hold) and hold > 0:
        notes.append(f"保持累計は {fmt_num(hold, 1)} 分です。改善幅に対して運用負荷が妥当か確認してください。")
    return notes


def format_candidate_table(df: pd.DataFrame) -> pd.DataFrame:
    rename = {
        "springGainSecPerStop": "スプリングゲイン",
        "springDeadbandStops": "スプリング不感帯",
        "adjustedAvgTotalMin": "補正平均総所要時間",
        "adjustedAvgTotal_vs_plain_pct": "制御なし比 補正総所要改善",
        "adjustedAvgTotal_vs_skip_pct": "skip比 補正総所要改善",
        "adjustedTop5TotalMin": "補正上位5%総所要時間",
        "avgTotalMin": "平均総所要時間",
        "avgTotal_vs_plain_pct": "制御なし比 総所要改善",
        "avgTotal_vs_skip_pct": "skip比 総所要改善",
        "avgWaitMin": "平均待ち時間",
        "avgWait_vs_plain_pct": "制御なし比 待ち改善",
        "avgWait_vs_skip_pct": "skip比 待ち改善",
        "headwayRmseStops": "車間RMSE",
        "headwayRmse_vs_plain_pct": "制御なし比 RMSE改善",
        "headwayRmse_vs_skip_pct": "skip比 RMSE改善",
        "maxHeadwayStops": "最大車間",
        "skippedPassengers": "スキップ人数",
        "totalSpringHoldMin": "保持累計分",
        "maxSpringHoldSec": "最大保持秒",
    }
    shown = df.rename(columns=rename).copy()
    shown = shown[[c for c in CANDIDATE_DISPLAY_COLUMNS if c in shown.columns]]
    formats = {
        "総合点": "{:.1f}",
        "スプリングゲイン": "{:.2f}",
        "スプリング不感帯": "{:.2f}",
        "補正平均総所要時間": "{:.2f}",
        "制御なし比 補正総所要改善": "{:+.1f}%",
        "skip比 補正総所要改善": "{:+.1f}%",
        "補正上位5%総所要時間": "{:.2f}",
        "平均総所要時間": "{:.2f}",
        "制御なし比 総所要改善": "{:+.1f}%",
        "skip比 総所要改善": "{:+.1f}%",
        "平均待ち時間": "{:.2f}",
        "制御なし比 待ち改善": "{:+.1f}%",
        "skip比 待ち改善": "{:+.1f}%",
        "車間RMSE": "{:.2f}",
        "制御なし比 RMSE改善": "{:+.1f}%",
        "skip比 RMSE改善": "{:+.1f}%",
        "最大車間": "{:.2f}",
        "スキップ人数": "{:.1f}",
        "保持累計分": "{:.1f}",
        "最大保持秒": "{:.1f}",
    }
    for column, fmt in formats.items():
        if column in shown:
            shown[column] = shown[column].map(lambda value, fmt=fmt: "-" if pd.isna(value) else fmt.format(value))
    return shown


def comparison_html(df: pd.DataFrame) -> str:
    rows = []
    shown = format_comparison_table(df)
    for row in shown.to_dict("records"):
        verdict = row.get("判定", "")
        color = "#2563eb" if verdict == "改善" else ("#dc2626" if verdict == "悪化" else "#6b7280")
        rows.append(
            "<tr>"
            f"<td>{html.escape(str(row.get('分類', '')))}</td>"
            f"<td>{html.escape(str(row.get('指標', '')))}</td>"
            f"<td>{html.escape(str(row.get('制御なし', '-')))}</td>"
            f"<td>{html.escape(str(row.get('スキップ制御', '-')))}</td>"
            f"<td><strong>{html.escape(str(row.get('スプリング法', '-')))}</strong></td>"
            f"<td style='color:{color};font-weight:700'>{html.escape(str(row.get('spring改善率 vs 制御なし', '-')))}</td>"
            f"<td style='color:{color};font-weight:700'>{html.escape(str(row.get('spring改善率 vs スキップ', '-')))}</td>"
            f"<td style='color:{color};font-weight:700'>{html.escape(str(verdict))}</td>"
            "</tr>"
        )
    return (
        "<table style='width:100%;border-collapse:collapse;font-size:0.92rem'>"
        "<thead><tr>"
        "<th style='text-align:left'>分類</th><th style='text-align:left'>指標</th>"
        "<th style='text-align:right'>制御なし</th><th style='text-align:right'>スキップ</th><th style='text-align:right'>スプリング</th>"
        "<th style='text-align:right'>vs 制御なし</th><th style='text-align:right'>vs スキップ</th><th style='text-align:left'>判定</th>"
        "</tr></thead><tbody>"
        + "".join(rows)
        + "</tbody></table>"
    )


st.set_page_config(page_title="バス団子運転 Sweep Lab", layout="wide")
st.title("バス団子運転 Sweep Lab")


@st.cache_data(show_spinner=False)
def load_run(run_dir: str) -> tuple[dict, pd.DataFrame, pd.DataFrame, pd.DataFrame, dict[str, pd.DataFrame]]:
    path = Path(run_dir)
    manifest = json.loads((path / "manifest.json").read_text(encoding="utf-8"))
    results = pd.read_parquet(path / "results.parquet")
    aggregate = pd.read_parquet(path / "aggregate.parquet")
    history = pd.read_parquet(path / "history.parquet")
    derivatives: dict[str, pd.DataFrame] = {}
    derivatives = derived_data.build_visual_derivatives(aggregate)
    return manifest, results, aggregate, history, derivatives


def available_runs(root: Path) -> list[Path]:
    if not root.exists():
        return []
    return sorted([p for p in root.iterdir() if (p / "manifest.json").exists()], key=lambda p: p.stat().st_mtime, reverse=True)


runs = available_runs(RUNS_ROOT)
if not runs:
    st.info(f"{RUNS_ROOT} 配下に実験結果がありません。先にCLIで実験を実行してください。")
    st.code("python -m bus_sweep.cli run --config configs/default_experiment.json --out runs/default --workers auto")
    st.stop()

run = st.selectbox("実験結果", runs, format_func=lambda p: p.name, label_visibility="collapsed")
manifest, results, aggregate, history, derivatives = load_run(str(run))

st.caption(f"seed数: {manifest.get('seed_count')}  シナリオ数: {manifest.get('scenario_count')}  worker数: {manifest.get('workers')}  計算時間: {manifest.get('elapsed_sec', 0):.1f}秒")

metrics = sorted_metrics(list(aggregate["metric"].unique()))
control_cols = st.columns([1.35, 1])
primary_metric = control_cols[0].selectbox(
    "主指標",
    metrics,
    index=metrics.index("adjustedAvgTotalMin") if "adjustedAvgTotalMin" in metrics else 0,
    format_func=metric_select_label,
)
mode = control_cols[1].selectbox("方式", sorted(aggregate["mode"].unique()), index=0, format_func=mode_label)

top = aggregate[(aggregate["metric"] == primary_metric) & (aggregate["mode"] == mode)].sort_values(
    "mean",
    ascending=metric_ascending(primary_metric),
)

decision = build_decision_table(aggregate)
candidate_table = build_candidate_table(aggregate)
metric_surfaces = derivatives.get("metric_surfaces", pd.DataFrame())
mode_deltas = derivatives.get("mode_deltas", pd.DataFrame())
param_cols = [c for c in top.columns if c not in {"scenario_id", "mode", "metric", "mean", "sd", "n"}]

terrain_tab, portfolio_tab, diff_tab, risk_tab, detail_tab, guide_tab = st.tabs(
    ["地形図", "候補ポートフォリオ", "方式差分", "リスク", "詳細", "指標ガイド"]
)

with terrain_tab:
    cols = st.columns(4)
    for col, label, value in [
        (cols[0], "結果行数", len(results)),
        (cols[1], "シナリオ数", manifest.get("scenario_count")),
        (cols[2], "seed数", manifest.get("seed_count")),
        (cols[3], "失敗数", manifest.get("failure_count")),
    ]:
        col.metric(label, value)

    st.subheader("パラメータ地形図")
    st.caption("青が良い、赤が悪い。各図の白丸はその指標の最良点、黒枠は制約付き総合点の上位候補です。")
    if not metric_surfaces.empty and len(param_cols) >= 2:
        surface_mode = st.selectbox("地形図の方式", sorted(metric_surfaces["mode"].unique()), index=sorted(metric_surfaces["mode"].unique()).index("spring") if "spring" in set(metric_surfaces["mode"].unique()) else 0, format_func=mode_label)
        available_surface_metrics = sorted_metrics(list(metric_surfaces["metric"].dropna().unique()))
        primary_surface_metrics = [m for m in derived_data.SURFACE_METRICS if m in set(available_surface_metrics)]
        surface_metrics = [*primary_surface_metrics, *[m for m in available_surface_metrics if m not in set(primary_surface_metrics)]]
        grid_cols = st.columns(3)
        x_param, y_param = param_cols[0], param_cols[1]

        def render_surface_cards(metrics_to_render: list[str]) -> None:
            for i, metric in enumerate(metrics_to_render):
                surface = metric_surfaces[(metric_surfaces["mode"].eq(surface_mode)) & (metric_surfaces["metric"].eq(metric))]
                if surface.empty:
                    continue
                heat = surface.pivot_table(index=y_param, columns=x_param, values="mean", aggfunc="mean")
                scale = "RdBu" if metric_direction(metric) > 0 else "RdBu_r"
                fig = px.imshow(
                    heat,
                    aspect="auto",
                    color_continuous_scale=scale,
                    labels={"x": param_label(x_param), "y": param_label(y_param), "color": metric_label(metric)},
                    title=metric_label(metric),
                )
                best_points = surface[surface["is_best"]]
                top_points = surface[surface["top10_candidate"]]
                if not top_points.empty:
                    fig.add_trace(
                        go.Scatter(
                            x=top_points[x_param],
                            y=top_points[y_param],
                            mode="markers",
                            marker={"size": 12, "color": "rgba(0,0,0,0)", "line": {"color": "#111827", "width": 2}},
                            name="上位候補",
                            hoverinfo="skip",
                        )
                    )
                if not best_points.empty:
                    fig.add_trace(
                        go.Scatter(
                            x=best_points[x_param],
                            y=best_points[y_param],
                            mode="markers",
                            marker={"size": 9, "color": "#ffffff", "line": {"color": "#111827", "width": 1}},
                            name="最良点",
                            hoverinfo="skip",
                        )
                    )
                fig.update_layout(height=330, margin={"l": 10, "r": 10, "t": 48, "b": 10}, coloraxis_showscale=False)
                grid_cols[i % 3].plotly_chart(fig, use_container_width=True)

        render_surface_cards(surface_metrics[:9])
        if len(surface_metrics) > 9:
            with st.expander(f"その他の小型指標地形図（{len(surface_metrics) - 9}指標）", expanded=False):
                grid_cols = st.columns(3)
                render_surface_cards(surface_metrics[9:])

        focus_metric = st.selectbox("大判地形図の指標", surface_metrics, index=0, format_func=metric_label)
        focus = metric_surfaces[(metric_surfaces["mode"].eq(surface_mode)) & (metric_surfaces["metric"].eq(focus_metric))]
        focus_heat = focus.pivot_table(index=y_param, columns=x_param, values="mean", aggfunc="mean")
        focus_fig = go.Figure(
            data=go.Contour(
                z=focus_heat.values,
                x=list(focus_heat.columns),
                y=list(focus_heat.index),
                colorscale="RdBu" if metric_direction(focus_metric) > 0 else "RdBu_r",
                contours={"coloring": "heatmap", "showlabels": True},
                colorbar={"title": metric_label(focus_metric)},
            )
        )
        focus_fig.update_layout(
            title=f"{metric_label(focus_metric)} 等高線地形図 - 青が良い、赤が悪い",
            xaxis_title=param_label(x_param),
            yaxis_title=param_label(y_param),
            height=560,
        )
        st.plotly_chart(focus_fig, use_container_width=True)
    else:
        st.info("地形図を作るには2変数以上のsweep結果が必要です。")

    st.subheader("地形図から読む結論")

    if not candidate_table.empty:
        recommended = candidate_table[candidate_table["判定"].eq("推奨")]
        best = recommended.iloc[0] if not recommended.empty else candidate_table.iloc[0]
        st.subheader("今回の結論")
        conclusion_cols = st.columns([1.35, 1, 1, 1])
        conclusion_cols[0].metric("最有力候補", best["判定"], best["scenario_label"])
        conclusion_cols[1].metric("総合点", fmt_num(best.get("総合点"), 1), best.get("注意理由", ""))
        conclusion_cols[2].metric("skip比 補正総所要改善", fmt_pct(best.get("adjustedAvgTotal_vs_skip_pct")), f"{fmt_num(best.get('adjustedAvgTotalMin'))}分")
        conclusion_cols[3].metric("skip比 RMSE改善", fmt_pct(best.get("headwayRmse_vs_skip_pct")), f"RMSE {fmt_num(best.get('headwayRmseStops'))}")

        notes = build_candidate_notes(best)
        st.markdown("".join(f"- {html.escape(note)}\n" for note in notes))
        st.info("団子度は補助診断です。採用判断では、補正総所要時間、待ち時間、車間RMSE、最大車間、副作用を優先します。")

        st.subheader("plain / skip / spring 重要指標比較")
        st.markdown(comparison_html(build_mode_comparison(aggregate, best["scenario_id"])), unsafe_allow_html=True)

        st.subheader("判断の順番")
        guide_cols = st.columns(4)
        guide_cols[0].metric("1. 補正総所要時間", "平均/上位5%", "未完了者を評価から落とさない")
        guide_cols[1].metric("2. 待ち時間", "平均/上位5%", "利用者が実感する改善")
        guide_cols[2].metric("3. 車間安定", "RMSE/最大車間", "団子度は補助確認")
        guide_cols[3].metric("4. 副作用", "スキップ/保持", "負担が過大なら除外")
    else:
        st.info("候補テーブルを作成できませんでした。spring方式の結果が含まれているか確認してください。")

with portfolio_tab:
    if candidate_table.empty:
        st.info("候補がありません。")
    else:
        left, right = st.columns([1.15, 1.35])
        with left:
            st.subheader("候補ランキング")
            verdicts = ["推奨", "注意", "保留", "除外候補"]
            selected_verdicts = st.multiselect("判定フィルタ", verdicts, default=verdicts)
            max_rows = st.slider("表示件数", min_value=5, max_value=min(100, len(candidate_table)), value=min(30, len(candidate_table)))
            filtered_candidates = candidate_table[candidate_table["判定"].isin(selected_verdicts)].head(max_rows)
            if filtered_candidates.empty:
                st.info("条件に合う候補がありません。判定フィルタを広げてください。")
                filtered_candidates = candidate_table.head(1)
            st.dataframe(format_candidate_table(filtered_candidates), use_container_width=True, hide_index=True)
            options = filtered_candidates.reset_index(drop=True)
            selected_idx = st.selectbox(
                "比較する候補",
                list(range(len(options))),
                format_func=lambda i: f"#{int(options.iloc[i]['順位'])} {options.iloc[i]['判定']} / 点 {options.iloc[i]['総合点']:.1f} / {options.iloc[i]['scenario_label']}",
            )
        with right:
            selected = options.iloc[selected_idx]
            st.subheader("選択候補の読み解き")
            metric_cols = st.columns(4)
            metric_cols[0].metric("判定", selected["判定"], selected["注意理由"])
            metric_cols[1].metric("skip比 補正総所要", fmt_pct(selected.get("adjustedAvgTotal_vs_skip_pct")), f"{fmt_num(selected.get('adjustedAvgTotalMin'))}分")
            metric_cols[2].metric("skip比 待ち", fmt_pct(selected.get("avgWait_vs_skip_pct")), f"{fmt_num(selected.get('avgWaitMin'))}分")
            metric_cols[3].metric("skip比 RMSE", fmt_pct(selected.get("headwayRmse_vs_skip_pct")), f"{fmt_num(selected.get('headwayRmseStops'))}")
            st.markdown("".join(f"- {html.escape(note)}\n" for note in build_candidate_notes(selected)))
            st.markdown(comparison_html(build_mode_comparison(aggregate, selected["scenario_id"])), unsafe_allow_html=True)

    st.subheader("候補ポートフォリオ")
with portfolio_tab:
    if not candidate_table.empty:
        tradeoff = candidate_table.copy()
        tradeoff_metrics = [m for m in KEY_COMPARISON_METRICS if m in tradeoff.columns]
        x_metric = st.selectbox(
            "トレードオフ地図 横軸",
            tradeoff_metrics,
            index=tradeoff_metrics.index("adjustedAvgTotalMin") if "adjustedAvgTotalMin" in tradeoff_metrics else 0,
            format_func=metric_label,
        )
        y_metric = st.selectbox(
            "トレードオフ地図 縦軸",
            tradeoff_metrics,
            index=tradeoff_metrics.index("headwayRmseStops") if "headwayRmseStops" in tradeoff_metrics else min(1, len(tradeoff_metrics) - 1),
            format_func=metric_label,
        )
        hover_data = {
            "総合点": ":.1f",
            "判定": True,
            "adjustedAvgTotalMin": ":.2f",
            "avgWaitMin": ":.2f",
            "avgTotalMin": ":.2f",
            "headwayRmseStops": ":.2f",
            "skippedPassengers": ":.1f",
            "totalSpringHoldMin": ":.1f",
            "注意理由": True,
        }
        fig = px.scatter(
            tradeoff,
            x=x_metric,
            y=y_metric,
            color="総合点",
            symbol="判定",
            hover_name="scenario_label",
            hover_data={k: v for k, v in hover_data.items() if k in tradeoff.columns},
            color_continuous_scale="Turbo",
            labels={
                x_metric: metric_label(x_metric),
                y_metric: metric_label(y_metric),
                "総合点": "制約付き総合点",
                "判定": "判定",
                "adjustedAvgTotalMin": "補正平均総所要時間",
                "avgWaitMin": "平均待ち時間",
                "avgTotalMin": "平均総所要時間",
                "headwayRmseStops": "車間RMSE",
                "skippedPassengers": "スキップ人数",
                "totalSpringHoldMin": "保持累計分",
            },
            title="色が明るいほど制約付き総合点が高い候補です。形で判定を分け、上位10件を黒枠で強調します。",
        )
        fig.update_traces(marker={"size": 7, "opacity": 0.82, "line": {"width": 0.7, "color": "#111827"}})
        top10 = tradeoff.head(10)
        fig.add_trace(
            go.Scatter(
                x=top10[x_metric],
                y=top10[y_metric],
                mode="markers",
                marker={"size": 15, "color": "rgba(0,0,0,0)", "line": {"color": "#111827", "width": 2.2}},
                name="上位10候補",
                hoverinfo="skip",
            )
        )
        fig.update_layout(height=560)
        st.plotly_chart(fig, use_container_width=True)

    if len(param_cols) >= 2:
        x = st.selectbox("ヒートマップ 横軸", param_cols, index=0, format_func=param_label)
        y_options = [col for col in param_cols if col != x]
        y = st.selectbox("ヒートマップ 縦軸", y_options, index=0, format_func=param_label)
        heat = top.pivot_table(index=y, columns=x, values="mean", aggfunc="mean")
        heat_scale = "RdBu" if metric_direction(primary_metric) > 0 else "RdBu_r"
        heat_fig = px.imshow(
            heat,
            aspect="auto",
            color_continuous_scale=heat_scale,
            title=f"{metric_label(primary_metric)} 平均 ({mode_label(mode)}) - 青が良い、赤が悪い",
            labels={"x": param_label(x), "y": param_label(y), "color": "平均"},
        )
        heat_fig.update_layout(height=520)
        st.plotly_chart(heat_fig, use_container_width=True)
    elif len(param_cols) == 1:
        line_top = top.sort_values(param_cols[0]).copy()
        line_top["mode_label"] = line_top["mode"].map(mode_label)
        st.plotly_chart(
            px.line(
                line_top,
                x=param_cols[0],
                y="mean",
                color="mode_label",
                markers=True,
                color_discrete_sequence=["#2563eb", "#dc2626", "#16a34a"],
                labels={param_cols[0]: param_label(param_cols[0]), "mean": "平均", "mode_label": "方式"},
            ),
            use_container_width=True,
        )

with diff_tab:
    st.subheader("方式差分")
    if candidate_table.empty:
        st.info("候補がありません。")
    else:
        diff_control_cols = st.columns([1.4, 1])
        verdicts = ["推奨", "注意", "保留", "除外候補"]
        diff_verdicts = diff_control_cols[0].multiselect("判定フィルタ", verdicts, default=verdicts, key="diff_verdict_filter")
        diff_max_rows = diff_control_cols[1].slider(
            "表示件数",
            min_value=5,
            max_value=min(100, len(candidate_table)),
            value=min(30, len(candidate_table)),
            key="diff_max_rows",
        )
        diff_options = candidate_table[candidate_table["判定"].isin(diff_verdicts)].head(diff_max_rows).reset_index(drop=True)
        if diff_options.empty:
            st.info("条件に合う候補がありません。判定フィルタを広げてください。")
            diff_options = candidate_table.head(1).reset_index(drop=True)
        diff_idx = st.selectbox(
            "差分を見る候補",
            list(range(len(diff_options))),
            format_func=lambda i: f"#{int(diff_options.iloc[i]['順位'])} {diff_options.iloc[i]['判定']} / {diff_options.iloc[i]['scenario_label']}",
        )
        scenario_id = diff_options.iloc[diff_idx]["scenario_id"]
        slope_metrics = ["adjustedAvgTotalMin", "adjustedTop5TotalMin", "avgWaitMin", "top5WaitMin", "headwayRmseStops", "maxHeadwayStops", "totalSpringHoldMin", "skippedPassengers", "bunchScore"]
        rows = aggregate[aggregate["scenario_id"].eq(scenario_id) & aggregate["metric"].isin(slope_metrics)].copy()
        rows["metric_label"] = rows["metric"].map(metric_label)
        rows["mode_label"] = rows["mode"].map(mode_label)
        slope = px.line(
            rows,
            x="mode_label",
            y="mean",
            color="metric_label",
            facet_col="metric_label",
            facet_col_wrap=4,
            markers=True,
            labels={"mode_label": "方式", "mean": "値", "metric_label": "指標"},
            title="plain → skip → spring のスロープ図",
        )
        slope.update_yaxes(matches=None, showticklabels=True)
        slope.update_layout(height=620, showlegend=False)
        st.plotly_chart(slope, use_container_width=True)

        if not mode_deltas.empty:
            deltas = mode_deltas[
                mode_deltas["scenario_id"].eq(scenario_id)
                & mode_deltas["target_mode"].eq("spring")
                & mode_deltas["base_mode"].isin(["plain", "skip"])
                & mode_deltas["metric"].isin(slope_metrics)
            ].copy()
            deltas["metric_label"] = deltas["metric"].map(metric_label)
            deltas["比較元"] = deltas["base_mode"].map(lambda value: "制御なし比" if value == "plain" else "skip比")
            deltas["color"] = deltas["improvement_pct"].map(lambda v: "改善" if pd.notna(v) and v > 0.5 else ("悪化" if pd.notna(v) and v < -0.5 else "同等"))
            bar = px.bar(
                deltas.sort_values("improvement_pct"),
                x="improvement_pct",
                y="metric_label",
                orientation="h",
                color="比較元",
                barmode="group",
                color_discrete_map={"制御なし比": "#2563eb", "skip比": "#f97316"},
                labels={"improvement_pct": "spring改善率 (%)", "metric_label": "指標"},
                title="spring の改善率 - 制御なし比 / skip比",
            )
            bar.update_layout(height=420)
            st.plotly_chart(bar, use_container_width=True)

with risk_tab:
    st.subheader("リスク分布")
    if candidate_table.empty:
        st.info("候補がありません。")
    else:
        risk_cols = st.columns(3)
        for col, metric, title in [
            (risk_cols[0], "totalSpringHoldMin", "保持累計分"),
            (risk_cols[1], "maxSpringHoldSec", "最大保持秒"),
            (risk_cols[2], "skippedPassengers", "スキップ人数"),
        ]:
            fig = px.histogram(
                candidate_table,
                x=metric,
                color="判定",
                nbins=24,
                color_discrete_map={"推奨": "#2563eb", "注意": "#f59e0b", "保留": "#6b7280", "除外候補": "#dc2626"},
                title=title,
            )
            fig.update_layout(height=300, showlegend=False)
            col.plotly_chart(fig, use_container_width=True)

        strip_metrics = ["adjustedAvgTotalMin", "adjustedTop5TotalMin", "totalSpringHoldMin", "maxSpringHoldSec", "skippedPassengers"]
        strips = candidate_table.melt(
            id_vars=["scenario_id", "判定", "順位", "scenario_label"],
            value_vars=[m for m in strip_metrics if m in candidate_table.columns],
            var_name="metric",
            value_name="value",
        )
        strips["metric_label"] = strips["metric"].map(metric_label)
        strip = px.strip(
            strips,
            x="value",
            y="metric_label",
            color="判定",
            hover_name="scenario_label",
            color_discrete_map={"推奨": "#2563eb", "注意": "#f59e0b", "保留": "#6b7280", "除外候補": "#dc2626"},
            title="制約・副作用の警告ストリップ",
        )
        strip.update_traces(marker={"size": 7, "opacity": 0.75})
        strip.update_layout(height=520)
        st.plotly_chart(strip, use_container_width=True)

with detail_tab:
    st.subheader("候補一覧")
    if not candidate_table.empty:
        st.dataframe(format_candidate_table(candidate_table), use_container_width=True, hide_index=True)
        candidate_csv = format_candidate_table(candidate_table).to_csv(index=False).encode("utf-8-sig")
        st.download_button("候補ランキングCSVをダウンロード", candidate_csv, file_name=f"{run.name}-candidate-ranking.csv", mime="text/csv")

    st.subheader("主指標ランキング")
    st.dataframe(display_table(top), use_container_width=True, hide_index=True)

    if not decision.empty:
        st.subheader("旧形式の意思決定テーブル")
        decision_shown = decision_display(decision)
        st.dataframe(
            format_decision_table(decision_shown),
            use_container_width=True,
            hide_index=True,
        )

    st.subheader("平均時系列")
    history_ready = not history.empty and {"scenario_id", "mode", "t"} <= set(history.columns)
    if history_ready:
        hist_metrics = [c for c in history.columns if c not in {"scenario_id", "seed", "mode", "t", *param_cols}]
        if hist_metrics:
            hist_metric = st.selectbox(
                "時系列指標",
                hist_metrics,
                index=0,
                format_func=metric_label,
            )
            scenario = st.selectbox("シナリオ", sorted(history["scenario_id"].unique()))
            hist = history[history["scenario_id"].eq(scenario)]
            hist_chart = hist.copy()
            hist_chart["mode_label"] = hist_chart["mode"].map(mode_label)
            st.plotly_chart(
                px.line(
                    hist_chart,
                    x="t",
                    y=hist_metric,
                    color="mode_label",
                    title=f"{metric_label(hist_metric)}: {scenario}",
                    labels={"t": "時刻秒", hist_metric: metric_label(hist_metric), "mode_label": "方式"},
                ),
                use_container_width=True,
            )
        else:
            st.info("時系列指標がありません。")
    else:
        st.info("このrunでは時系列履歴を保存していません。広い探索では高速化のためOFFにし、候補を絞った最終runで `history.aggregate` を `true` にしてください。")

with guide_tab:
    st.markdown(
        "広い探索では、まず `補正平均総所要時間`、`平均待ち時間`、`上位5%待ち時間`、`車間RMSE`、`最大車間`、"
        "`スキップ人数`、`スプリング保持累計` を見ます。団子度は補助診断として使います。"
    )
    st.markdown(metric_guide_html(), unsafe_allow_html=True)

with st.expander("実験メタデータ"):
    st.json(manifest)

with st.expander("実行コマンド例"):
    st.code("python -m bus_sweep.cli run --config configs/default_experiment.json --out runs/new-run --workers auto")
    if st.button("実験フォルダをExplorerで開く"):
        subprocess.Popen(["explorer", str(run.resolve())])
