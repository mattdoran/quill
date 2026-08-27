import logging
import time
from pathlib import Path

from flask import Flask, abort, redirect, render_template, request, send_file, url_for

from .core import assign, load_run, load_session, score, segment_key, summarize
from .storage import LABELS, annotation_path, read_annotations, write_annotations

logger = logging.getLogger(__name__)


def create_app(session_path: Path, run_paths: dict[str, Path], home: Path) -> Flask:
    app = Flask(__name__)
    session = load_session(session_path)
    runs = [load_run(name, path) for name, path in run_paths.items()]
    annotation_file = annotation_path(home, session.audio_sha256)
    app.config.update(VERSION=str(time.time_ns()), ANNOTATION_PATH=annotation_file)

    @app.get("/")
    def index():
        annotations = read_annotations(annotation_file, session.audio_sha256)
        rows = []
        run_assignments = {run.name: [] for run in runs}
        for segment in session.remote_segments:
            assignments = {}
            for run in runs:
                assignment = assign(segment, run.spans)
                assignments[run.name] = assignment
                run_assignments[run.name].append(assignment)
            rows.append(
                {
                    "segment": segment,
                    "key": segment_key(segment),
                    "annotation": annotations.get(segment_key(segment)),
                    "assignments": assignments,
                }
            )
        summaries = {}
        for run in runs:
            summaries[run.name] = summarize(run_assignments[run.name], len(run.spans))
            summaries[run.name]["score"] = score(
                session.remote_segments, run_assignments[run.name], annotations
            )
        return render_template(
            "index.html",
            session=session,
            rows=rows,
            runs=runs,
            summaries=summaries,
            labels=sorted(LABELS, key=("A", "B", "C", "Mixed", "Unclear").index),
        )

    @app.post("/annotations")
    def save_annotations():
        if request.headers.get("Sec-Fetch-Site") not in {None, "same-origin"}:
            abort(403)
        valid_keys = {segment_key(segment) for segment in session.remote_segments}
        labels = {
            key.removeprefix("label:"): value
            for key, value in request.form.items()
            if key.startswith("label:") and key.removeprefix("label:") in valid_keys and value
        }
        write_annotations(annotation_file, session.audio_sha256, session.path.name, labels)
        return redirect(url_for("index"), code=303)

    @app.get("/audio")
    def audio():
        return send_file(session.audio, conditional=True)

    @app.post("/api/log")
    def browser_log():
        payload = request.get_json(silent=True) or {}
        logger.error("browser error: %s", payload)
        return "", 204

    return app
