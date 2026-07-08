from datetime import datetime, timezone

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="Job-Hunt Agent API")

# Dev-only: lets Flutter web (served from its own localhost port) call this
# API from the browser. Native iOS/Android builds never hit CORS at all —
# it's a browser-only restriction — so this only matters while testing on
# the "Chrome (web)" device target during development.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health():
    return {
        "data": {"status": "ok", "time": datetime.now(timezone.utc).isoformat()},
        "error": None,
    }
