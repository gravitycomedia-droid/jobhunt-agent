from datetime import datetime, timezone

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from routers import applications, jobs, matches, pipeline, resume, stats, tailor, tasks

app = FastAPI(title="Job-Hunt Agent API")

app.include_router(resume.router)
app.include_router(jobs.router)
app.include_router(matches.router)
app.include_router(tailor.router)
app.include_router(applications.router)
app.include_router(pipeline.router)
app.include_router(stats.router)
app.include_router(tasks.router)

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
