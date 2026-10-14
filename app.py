import json
import uuid
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from embedder import Embedder
from matcher import Matcher

ROOT = Path(__file__).parent
DATA = ROOT / "data"
PROFILES_FILE = DATA / "profiles.json"
ME_FILE = DATA / "me.json"


class Prefer(BaseModel):
    gender: Literal["남", "여", "상관없음"] = "상관없음"
    age_min: int = 19
    age_max: int = 60


class Profile(BaseModel):
    id: str | None = None
    name: str
    gender: Literal["남", "여"]
    age: int = Field(ge=19, le=99)
    region: str = ""
    mbti: str = ""
    smoking: bool = False
    drinking: Literal["안 마심", "가끔", "자주"] = "가끔"
    bio: str = ""
    values: str = ""
    ideal: str = ""
    interests: list[str] = []
    prefer: Prefer = Prefer()
    source: Literal["virtual", "friend", "me"] = "friend"


def load_json(path: Path, default):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else default


def save_json(path: Path, data) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


app = FastAPI(title="Match Lab")
matcher = Matcher(Embedder())


@app.on_event("startup")
def warm_up():
    # 저장소 프로필을 미리 임베딩해 두면 첫 매칭이 빠르다
    for p in load_json(PROFILES_FILE, []):
        matcher.vectorize(p)


@app.get("/api/me")
def get_me():
    return load_json(ME_FILE, None)


@app.put("/api/me")
def put_me(p: Profile):
    data = p.model_dump()
    data.update(id="me", source="me")
    save_json(ME_FILE, data)
    return data


@app.get("/api/profiles")
def list_profiles():
    return load_json(PROFILES_FILE, [])


@app.post("/api/profiles")
def add_profile(p: Profile):
    profiles = load_json(PROFILES_FILE, [])
    data = p.model_dump()
    data["id"] = uuid.uuid4().hex[:8]
    profiles.append(data)
    save_json(PROFILES_FILE, profiles)
    return data


@app.delete("/api/profiles/{pid}")
def delete_profile(pid: str):
    profiles = load_json(PROFILES_FILE, [])
    kept = [p for p in profiles if p["id"] != pid]
    if len(kept) == len(profiles):
        raise HTTPException(404, "프로필 없음")
    save_json(PROFILES_FILE, kept)
    return {"ok": True}


@app.post("/api/match")
def match():
    me = load_json(ME_FILE, None)
    if me is None:
        raise HTTPException(400, "먼저 내 프로필을 저장하세요")
    return matcher.rank(me, load_json(PROFILES_FILE, []))


@app.get("/")
def index():
    return FileResponse(ROOT / "static" / "index.html")


app.mount("/static", StaticFiles(directory=ROOT / "static"), name="static")
