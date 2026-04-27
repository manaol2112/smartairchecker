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
    scale_max_ohms: float = 100_000.0,
    score_label_good_min: int = 67,
    score_label_moderate_min: int = 34,
) -> AirQualityResult:
    if gas_ohms < min_gas_ohms or gas_ohms <= 0:
        label: QualityLabel = "bad"
        score = 0
        return AirQualityResult(label=label, gas_ohms=gas_ohms, score_0_100=score)

    # When use_relative_score is true, the 0-100 value comes from scale or baseline
    # ratio. Using gas_ohms good_min/moderate_min for the *label* then disagrees with
    # the score (e.g. score 30 but “good” because Ω is above 20k). LED/buzzer use label.
    label_from_score = False
    if use_relative_score and scale_max_ohms > scale_min_ohms:
        # Linear map: higher gas (Ω) = cleaner. score 0 at scale_min, 100 at scale_max.
        # Default max 100k matches many indoor BME680 “best” readings; if you never see
        # ~100 in clean air, set scale_max_ohms slightly above your best kΩ×1000.
        t = 100.0 * (gas_ohms - scale_min_ohms) / (scale_max_ohms - scale_min_ohms)
        score = int(max(0, min(100, round(t))))
        label_from_score = True
    elif use_relative_score and baseline_ohms > 0:
        # Legacy: ratio to baseline_ohms. Note: this pins score at 100 for any
        # gas_ohms >= baseline_ohms, so a purifier with modest VOC changes can look “stuck”.
        ratio = min(2.0, max(0.0, gas_ohms / baseline_ohms))
        score = int(max(0, min(100, round(ratio * 100))))
        label_from_score = True
    else:
        if gas_ohms >= good_min:
            score = 100
        elif gas_ohms >= moderate_min:
            score = 55
        else:
            score = 20

    if label_from_score:
        # Require 1 <= sg <= 100 and 0 <= sm < sg so the three bands are well-defined
        sg = max(1, min(100, int(score_label_good_min)))
        sm = max(0, min(99, int(score_label_moderate_min)))
        if sm >= sg:
            sm = sg - 1
        if score >= sg:
            label: QualityLabel = "good"
        elif score >= sm:
            label = "moderate"
        else:
            label = "bad"
    elif gas_ohms >= good_min:
        label = "good"
    elif gas_ohms >= moderate_min:
        label = "moderate"
    else:
        label = "bad"

    return AirQualityResult(label=label, gas_ohms=gas_ohms, score_0_100=score)
