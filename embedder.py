"""텍스트 → 벡터 변환기.

기본은 API 키가 필요 없는 로컬 다국어 모델(fastembed, ONNX)을 쓴다.
다른 임베딩(OpenAI, Voyage 등)으로 바꾸려면 `_embed_raw`만 교체하면 된다.
"""
import hashlib
import re

import numpy as np
from fastembed import TextEmbedding

# 한국어 쌍 벤치마크에서 '비슷한 쌍 > 다른 쌍' 순서를 전부 맞힌 모델 (MiniLM은 변별력이 거의 없었음)
MODEL_NAME = "google/embeddinggemma-300m"
DIM = 768

_SENTENCE_SPLIT = re.compile(r"(?<=[.!?。~])\s+|\n+")


def split_sentences(text: str) -> list[str]:
    parts = [p.strip(" .!?~") for p in _SENTENCE_SPLIT.split(text or "")]
    return [p for p in parts if len(p) >= 2]


class Embedder:
    def __init__(self, model_name: str = MODEL_NAME):
        self.model = TextEmbedding(model_name=model_name)
        self._cache: dict[str, np.ndarray] = {}

    @staticmethod
    def _key(text: str) -> str:
        return hashlib.sha1(text.encode("utf-8")).hexdigest()

    def _embed_raw(self, texts: list[str]) -> list[np.ndarray]:
        return list(self.model.embed(texts))

    def embed_many(self, texts: list[str]) -> np.ndarray:
        """여러 문장을 정규화된 벡터 행렬로. 이미 계산한 문장은 캐시에서 꺼낸다."""
        missing = [t for t in dict.fromkeys(texts) if self._key(t) not in self._cache]
        if missing:
            for t, v in zip(missing, self._embed_raw(missing)):
                v = np.asarray(v, dtype=np.float32)
                self._cache[self._key(t)] = v / (np.linalg.norm(v) + 1e-9)
        if not texts:
            return np.zeros((0, DIM), dtype=np.float32)
        return np.stack([self._cache[self._key(t)] for t in texts])

    def embed_text(self, text: str) -> np.ndarray | None:
        """긴 글은 문장 단위로 임베딩한 뒤 평균낸다 (모델 입력 길이 제한 회피)."""
        sentences = split_sentences(text)
        if not sentences:
            return None
        v = self.embed_many(sentences).mean(axis=0)
        return v / (np.linalg.norm(v) + 1e-9)
