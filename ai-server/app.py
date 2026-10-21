"""교만추 AI 설명 API (파이썬 표준 라이브러리만 사용) — 이 PC 의 Ollama 를 Cloudflare 터널로 공개할 때 쓰는 입구

공개하는 것은 두 개뿐이다. Ollama 자체(모델 받기 · 지우기 등)는 밖에서 부를 수 없다.
  POST /embed    {"texts": [나, 후보1, 후보2, ...]}  → {"sims": [후보1과의 유사도, ...]}
  POST /explain  {"facts": ["근거 문장", ...], "sample": false} → {"text": "설명", "model": ...}
  GET  /         상태 확인 (서버가 깨어 있는지)
"""
import json
import math
import os
import re
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OLLAMA = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
LLM = os.environ.get("LLM_MODEL", "exaone3.5:2.4b")
EMBED = os.environ.get("EMBED_MODEL", "qwen3-embedding:0.6b")
ALLOWED_ORIGINS = {"https://beggarking.github.io", "http://localhost:8765", "http://127.0.0.1:8765"}
SYSTEM = (
    "너는 소개팅 앱의 추천 설명 도우미야. 사용자가 주는 문장들만 자연스럽게 이어서 왜 1위인지 2~3문장으로 설명해. "
    "문장에 없는 내용, 해석, 평가는 절대 덧붙이지 마. '압도적', '독보적', '완벽' 같은 과장 표현과 "
    "'~것 같습니다', '~로 보입니다' 같은 추측 표현은 쓰지 마. 이름과 숫자는 그대로 쓰고, 한국어 존댓말로만 써."
)
EXAMPLE_FACTS = ["하늘님이 64.3점으로 1위예요.", "2위 별님보다 2.6점 높아요.", "2위와 비교해 가장 크게 앞선 항목은 생활 조건이에요.",
                 "회원님과 하늘님은 둘 다 요리, 베이킹을 좋아해요.", "만남 목적에 대한 답이 같아요."]
EXAMPLE_ANSWER = ("하늘님이 64.3점으로 1위예요. 2위 별님보다 2.6점 높은데, 가장 크게 앞선 항목은 생활 조건이에요. "
                  "회원님과 하늘님은 둘 다 요리와 베이킹을 좋아하고, 만남 목적에 대한 답도 같아요.")
OVERSTATED = re.compile(r"(압도적|독보적|완벽)(인|으로|한|하게)?\s*")
cpu_lock = threading.Lock()  # CPU 서버라 생성은 한 번에 하나씩


def ollama(path, body, timeout=300):
    req = urllib.request.Request(OLLAMA + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def str_list(value, max_items, max_len):
    if not isinstance(value, list) or not 1 <= len(value) <= max_items:
        raise ValueError("bad_input")
    out = []
    for v in value:
        if not isinstance(v, str) or not v.strip() or len(v) > max_len:
            raise ValueError("bad_input")
        out.append(v.strip())
    return out


def embed(data):
    texts = str_list(data.get("texts"), 8, 400)
    if len(texts) < 2:
        raise ValueError("bad_input")
    vecs = ollama("/api/embed", {"model": EMBED, "input": texts})["embeddings"]
    norm = lambda v: math.sqrt(sum(x * x for x in v)) or 1.0
    me = vecs[0]
    return {"sims": [sum(a * b for a, b in zip(me, v)) / (norm(me) * norm(v)) for v in vecs[1:]], "model": EMBED}


def explain(data):
    facts = str_list(data.get("facts"), 8, 200)
    ask = lambda fs: "다음 문장들을 자연스럽게 이어 주세요.\n" + "\n".join(f"{i + 1}. {f}" for i, f in enumerate(fs))
    options = {"temperature": 0.3 if data.get("sample") else 0, "top_p": 0.9, "repeat_penalty": 1.1, "num_predict": 160}
    with cpu_lock:
        r = ollama("/api/chat", {
            "model": LLM, "stream": False, "think": False, "options": options,
            "messages": [{"role": "system", "content": SYSTEM},
                         # 말투 예시 (이름 · 숫자는 실제와 겹치지 않게)
                         {"role": "user", "content": ask(EXAMPLE_FACTS)}, {"role": "assistant", "content": EXAMPLE_ANSWER},
                         {"role": "user", "content": ask(facts)}],
        })
    # 작은 모델이 자꾸 붙이는 과장 표현은 지운다 (예: "압도적인 1위" → "1위")
    text = OVERSTATED.sub("", r["message"]["content"]).strip()
    return {"text": text, "model": LLM,
            "seconds": round(r.get("total_duration", 0) / 1e9, 1)}


class Handler(BaseHTTPRequestHandler):
    def cors(self):
        origin = self.headers.get("Origin", "")
        if origin in ALLOWED_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def reply(self, status, body):
        raw = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.end_headers()

    def do_GET(self):
        if self.path != "/":
            return self.reply(404, {"error": "not_found"})
        try:
            urllib.request.urlopen(OLLAMA + "/api/version", timeout=5)
            self.reply(200, {"ok": True, "llm": LLM, "embed": EMBED})
        except Exception:
            self.reply(503, {"ok": False, "error": "ollama_starting"})

    def do_POST(self):
        routes = {"/embed": embed, "/explain": explain}
        if self.path not in routes:
            return self.reply(404, {"error": "not_found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length > 20000:
                raise ValueError("bad_input")
            data = json.loads(self.rfile.read(length) or b"{}")
            self.reply(200, routes[self.path](data))
        except ValueError as e:
            self.reply(400, {"error": str(e) or "bad_input"})
        except Exception as e:  # Ollama 가 아직 켜지는 중이거나 모델 로딩 실패
            self.reply(503, {"error": "llm_unavailable", "detail": str(e)[:200]})

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    print(f"교만추 AI API: LLM={LLM}, EMBED={EMBED}", flush=True)
    # 이 PC 안에서만 연다. 밖에서는 Cloudflare 터널을 통해서만 들어온다
    ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("PORT", 7860))), Handler).serve_forever()
