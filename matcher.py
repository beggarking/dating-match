"""추천 로직: 내 프로필 vs 저장소의 각 프로필을 1:1로 비교해 점수 + 근거를 만든다.

총점(0~100) = Σ 가중치 × 항목점수(0~1) × 100

  항목             가중치  계산 방법
  ─────────────────────────────────────────────────────────────────────
  이상형 상호적합   0.30   내 이상형 ↔ 상대 자기서술, 상대 이상형 ↔ 내 자기서술
                          두 방향 임베딩 유사도의 조화평균 (한쪽만 높으면 깎임)
  가치관 유사도     0.25   가치관 글 임베딩 코사인 유사도
  관심사 매칭       0.20   관심사 하나하나를 임베딩해 의미가 가까운 쌍을 찾음
                          (예: 등산 ↔ 캠핑) — 글자가 달라도 매칭됨
  자기소개 결       0.10   자기소개 글 임베딩 코사인 유사도
  생활 조건         0.15   나이차 · 지역 · 흡연 · 음주 (규칙 기반)

필수 조건(서로의 선호 성별, 선호 나이 범위)을 통과하지 못하면 점수 계산 없이 제외하고,
제외 사유도 함께 돌려준다.
"""
from dataclasses import dataclass

import numpy as np

from embedder import Embedder, split_sentences

WEIGHTS = {
    "ideal": 0.30,
    "values": 0.25,
    "interests": 0.20,
    "bio": 0.10,
    "lifestyle": 0.15,
}
LABELS = {
    "ideal": "이상형 상호적합",
    "values": "가치관 유사도",
    "interests": "관심사 매칭",
    "bio": "자기소개 결",
    "lifestyle": "생활 조건",
}

# 코사인 유사도 → 0~1 점수 보정 구간.
# embeddinggemma는 무관한 문장끼리도 0.35~0.55가 나오므로 0.45 아래는 0점, 0.85 이상은 만점으로 본다.
SIM_FLOOR, SIM_CEIL = 0.45, 0.85
INTEREST_MATCH_MIN = 0.64  # 관심사 쌍을 "매칭"으로 볼 최소 원시 유사도
SENTENCE_MATCH_MIN = 0.6  # "비슷한 문장"으로 보여줄 최소 원시 유사도
DRINK_LEVELS = {"안 마심": 0, "가끔": 1, "자주": 2}


def calibrate(sim: float) -> float:
    return float(np.clip((sim - SIM_FLOOR) / (SIM_CEIL - SIM_FLOOR), 0.0, 1.0))


def cos(a, b) -> float:
    if a is None or b is None:
        return 0.0
    return float(np.dot(a, b))


def level(score: float) -> str:
    if score >= 0.75:
        return "매우 높음"
    if score >= 0.5:
        return "높음"
    if score >= 0.3:
        return "보통"
    return "낮음"


def self_text(p: dict) -> str:
    """상대의 이상형과 비교할 '나를 설명하는 글' = 자기소개 + 가치관 + 관심사."""
    interests = ", ".join(p.get("interests", []))
    return f"{p.get('bio', '')}\n{p.get('values', '')}\n관심사는 {interests}."


@dataclass
class Vectors:
    bio: np.ndarray | None
    values: np.ndarray | None
    ideal: np.ndarray | None
    self_: np.ndarray | None
    interests: np.ndarray
    sentences: list[str]
    sentence_vecs: np.ndarray


class Matcher:
    def __init__(self, embedder: Embedder):
        self.emb = embedder

    def vectorize(self, p: dict) -> Vectors:
        sentences = split_sentences(p.get("bio", "")) + split_sentences(p.get("values", ""))
        return Vectors(
            bio=self.emb.embed_text(p.get("bio", "")),
            values=self.emb.embed_text(p.get("values", "")),
            ideal=self.emb.embed_text(p.get("ideal", "")),
            self_=self.emb.embed_text(self_text(p)),
            interests=self.emb.embed_many(p.get("interests", [])),
            sentences=sentences,
            sentence_vecs=self.emb.embed_many(sentences),
        )

    # ── 필수 조건 ────────────────────────────────────────────────
    @staticmethod
    def hard_filter(me: dict, other: dict) -> list[str]:
        reasons = []
        my_pref, their_pref = me.get("prefer", {}), other.get("prefer", {})
        if my_pref.get("gender") not in (None, "", "상관없음", other.get("gender")):
            reasons.append(f"내 선호 성별({my_pref['gender']})과 다름")
        if their_pref.get("gender") not in (None, "", "상관없음", me.get("gender")):
            reasons.append(f"상대의 선호 성별({their_pref['gender']})에 내가 해당하지 않음")
        lo, hi = my_pref.get("age_min", 0), my_pref.get("age_max", 200)
        if not lo <= other["age"] <= hi:
            reasons.append(f"상대 나이 {other['age']}세가 내 선호 범위({lo}~{hi}) 밖")
        lo, hi = their_pref.get("age_min", 0), their_pref.get("age_max", 200)
        if not lo <= me["age"] <= hi:
            reasons.append(f"내 나이 {me['age']}세가 상대 선호 범위({lo}~{hi}) 밖")
        return reasons

    # ── 항목별 점수 ──────────────────────────────────────────────
    @staticmethod
    def score_ideal(mv: Vectors, ov: Vectors) -> dict:
        to_them = calibrate(cos(mv.ideal, ov.self_))
        to_me = calibrate(cos(ov.ideal, mv.self_))
        score = 0.0 if to_them + to_me == 0 else 2 * to_them * to_me / (to_them + to_me)
        return {"score": score, "to_them": to_them, "to_me": to_me}

    @staticmethod
    def score_interests(me: dict, other: dict, mv: Vectors, ov: Vectors) -> dict:
        mine, theirs = me.get("interests", []), other.get("interests", [])
        if not mine or not theirs:
            return {"score": 0.0, "pairs": []}
        sim = mv.interests @ ov.interests.T
        # 양방향으로 "가장 가까운 짝"의 보정 점수를 평균 → 서로의 관심사가 얼마나 겹치는지
        fwd = np.mean([calibrate(s) for s in sim.max(axis=1)])
        bwd = np.mean([calibrate(s) for s in sim.max(axis=0)])
        pairs, used = [], set()
        for i, j in sorted(np.ndindex(sim.shape), key=lambda ij: -sim[ij]):
            if sim[i, j] < INTEREST_MATCH_MIN:
                break
            if i in used or ("t", j) in used:
                continue
            used.update({i, ("t", j)})
            pairs.append({"mine": mine[i], "theirs": theirs[j], "sim": round(float(sim[i, j]), 2)})
        return {"score": float((fwd + bwd) / 2), "pairs": pairs}

    @staticmethod
    def score_lifestyle(me: dict, other: dict) -> dict:
        details = []
        gap = abs(me["age"] - other["age"])
        age = 1.0 if gap <= 2 else max(0.0, 1 - 0.15 * (gap - 2))
        details.append({"item": "나이차", "value": f"{gap}살", "score": age})

        same_region = me.get("region") == other.get("region")
        details.append({
            "item": "지역",
            "value": "같음" if same_region else f"{me.get('region')} / {other.get('region')}",
            "score": 1.0 if same_region else 0.4,
        })

        smoke_ok = bool(me.get("smoking")) == bool(other.get("smoking"))
        details.append({
            "item": "흡연",
            "value": "일치" if smoke_ok else "불일치",
            "score": 1.0 if smoke_ok else 0.2,
        })

        d = abs(DRINK_LEVELS.get(me.get("drinking"), 1) - DRINK_LEVELS.get(other.get("drinking"), 1))
        details.append({
            "item": "음주",
            "value": f"{me.get('drinking')} / {other.get('drinking')}",
            "score": [1.0, 0.6, 0.2][d],
        })
        return {"score": float(np.mean([x["score"] for x in details])), "details": details}

    @staticmethod
    def best_sentence_pairs(mv: Vectors, ov: Vectors, k: int = 2) -> list[dict]:
        """내 글과 상대 글에서 의미가 가장 가까운 문장 쌍 — '왜 비슷한지'를 원문으로 보여준다."""
        if not len(mv.sentences) or not len(ov.sentences):
            return []
        sim = mv.sentence_vecs @ ov.sentence_vecs.T
        pairs, used_i, used_j = [], set(), set()
        for i, j in sorted(np.ndindex(sim.shape), key=lambda ij: -sim[ij]):
            if len(pairs) == k or sim[i, j] < SENTENCE_MATCH_MIN:
                break
            if i in used_i or j in used_j:
                continue
            used_i.add(i)
            used_j.add(j)
            pairs.append({"mine": mv.sentences[i], "theirs": ov.sentences[j], "sim": round(float(sim[i, j]), 2)})
        return pairs

    # ── 설명 문장 ────────────────────────────────────────────────
    @staticmethod
    def explain(other: dict, parts: dict) -> tuple[str, list[str], list[str]]:
        reasons, cautions = [], []
        ideal, inter, life = parts["ideal"], parts["interests"], parts["lifestyle"]

        if ideal["score"] >= 0.5:
            reasons.append(
                f"서로의 이상형에 잘 맞아요 — 내 이상형↔{other['name']} {ideal['to_them']:.0%}, "
                f"{other['name']}의 이상형↔나 {ideal['to_me']:.0%}"
            )
        elif max(ideal["to_them"], ideal["to_me"]) >= 0.5:
            who = "내가 상대에게" if ideal["to_them"] >= ideal["to_me"] else "상대가 나에게"
            cautions.append(
                f"이상형 적합도가 한쪽으로 치우쳐 있어요 ({who} 더 끌릴 가능성: "
                f"{ideal['to_them']:.0%} vs {ideal['to_me']:.0%})"
            )

        if parts["values"]["score"] >= 0.5:
            reasons.append(f"연애관·가치관 글의 의미가 비슷해요 ({level(parts['values']['score'])})")
        elif parts["values"]["score"] < 0.3:
            cautions.append("가치관 글의 방향이 꽤 달라요")

        if inter["pairs"]:
            pairs = ", ".join(f"{p['mine']}↔{p['theirs']}" for p in inter["pairs"][:3])
            reasons.append(f"관심사가 통해요: {pairs}")

        if parts["bio"]["score"] >= 0.5:
            reasons.append("자기소개에서 느껴지는 성향·분위기가 비슷해요")

        for d in life["details"]:
            if d["score"] <= 0.4:
                cautions.append(f"{d['item']}: {d['value']}")

        top = max(WEIGHTS, key=lambda k: WEIGHTS[k] * parts[k]["score"])
        headline = f"가장 크게 작용한 요소는 '{LABELS[top]}'"
        return headline, reasons, cautions

    # ── 전체 매칭 ────────────────────────────────────────────────
    def rank(self, me: dict, pool: list[dict]) -> dict:
        mv = self.vectorize(me)
        results, excluded = [], []
        for other in pool:
            if other.get("id") == me.get("id"):
                continue
            blocked = self.hard_filter(me, other)
            if blocked:
                excluded.append({"profile": other, "reasons": blocked})
                continue
            ov = self.vectorize(other)
            parts = {
                "ideal": self.score_ideal(mv, ov),
                "values": {"score": calibrate(cos(mv.values, ov.values))},
                "interests": self.score_interests(me, other, mv, ov),
                "bio": {"score": calibrate(cos(mv.bio, ov.bio))},
                "lifestyle": self.score_lifestyle(me, other),
            }
            headline, reasons, cautions = self.explain(other, parts)
            breakdown = [
                {
                    "key": k,
                    "label": LABELS[k],
                    "weight": WEIGHTS[k],
                    "score": round(parts[k]["score"], 3),
                    "points": round(WEIGHTS[k] * parts[k]["score"] * 100, 1),
                }
                for k in WEIGHTS
            ]
            results.append({
                "profile": other,
                "total": round(sum(b["points"] for b in breakdown), 1),
                "breakdown": breakdown,
                "headline": headline,
                "reasons": reasons,
                "cautions": cautions,
                "interest_pairs": parts["interests"]["pairs"],
                "sentence_pairs": self.best_sentence_pairs(mv, ov),
                "ideal": {k: round(v, 3) for k, v in parts["ideal"].items()},
                "lifestyle": parts["lifestyle"]["details"],
            })
        results.sort(key=lambda r: -r["total"])
        for i, r in enumerate(results, 1):
            r["rank"] = i
        return {
            "results": results,
            "excluded": excluded,
            "logic": {
                "weights": [{"key": k, "label": LABELS[k], "weight": w} for k, w in WEIGHTS.items()],
                "calibration": {"floor": SIM_FLOOR, "ceil": SIM_CEIL},
                "interest_match_min": INTEREST_MATCH_MIN,
            },
        }
