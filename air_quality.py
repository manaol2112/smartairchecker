from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

QualityLabel = Literal["good", "moderate", "bad"]


@dataclass
class AirQualityResult:
    label: QualityLabel
    gas_ohms: float
    score_0_100: int  # higher = cleaner air (for chart)


def evaluate_air_quality(
    gas_ohms: float,
    good_min: float,
    moderate_min: float,
    min_gas_ohms: float,
    baseline_ohms: float,
    use_relative_score: bool,
    scale_min_ohms: float = 10_000.0,
    scale_max_ohms: float = 200_000.0,
) -> AirQualityResult:
    if gas_ohms < min_gas_ohms or gas_ohms <= 0:
        label: QualityLabel = "bad"
        score = 0
        return AirQualityResult(label=label, gas_ohms=gas_ohms, score_0_100=score)

    if use_relative_score and scale_max_ohms > scale_min_ohms:
        # Linear map: higher gas (Ω) = cleaner. Below min → 0, at/above max → 100.
        t = 100.0 * (gas_ohms - scale_min_ohms) / (scale_max_ohms - scale_min_ohms)
        score = int(max(0, min(100, round(t))))
    elif use_relative_score and baseline_ohms > 0:
        # Legacy: ratio to baseline_ohms. Note: this pins score at 100 for any
        # gas_ohms >= baseline_ohms, so a purifier with modest VOC changes can look “stuck”.
        ratio = min(2.0, max(0.0, gas_ohms / baseline_ohms))
        score = int(max(0, min(100, round(ratio * 100))))
    else:
        if gas_ohms >= good_min:
            score = 100
        elif gas_ohms >= moderate_min:
            score = 55
        else:
            score = 20

    if gas_ohms >= good_min:
        label = "good"
    elif gas_ohms >= moderate_min:
        label = "moderate"
    else:
        label = "bad"

    return AirQualityResult(label=label, gas_ohms=gas_ohms, score_0_100=score)
