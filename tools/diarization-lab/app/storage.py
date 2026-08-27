import contextlib
import json
import os
import tempfile
from datetime import UTC, datetime
from pathlib import Path

SCHEMA_VERSION = 1
LABELS = {"A", "B", "C", "Mixed", "Unclear"}


def annotation_path(home: Path, audio_sha256: str) -> Path:
    return home / "data" / "annotations" / f"{audio_sha256}.json"


def read_annotations(path: Path, audio_sha256: str) -> dict[str, str]:
    if not path.exists():
        return {}
    with path.open() as handle:
        document = json.load(handle)
    if document.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"unsupported annotation schema: {document.get('schema_version')}")
    if document.get("audio_sha256") != audio_sha256:
        raise ValueError("annotation audio fingerprint does not match the selected recording")
    labels = document.get("labels", {})
    invalid = set(labels.values()) - LABELS
    if invalid:
        raise ValueError(f"unsupported annotation labels: {sorted(invalid)}")
    return labels


def write_annotations(path: Path, audio_sha256: str, session_name: str, labels: dict[str, str]):
    invalid = set(labels.values()) - LABELS
    if invalid:
        raise ValueError(f"unsupported annotation labels: {sorted(invalid)}")
    document = {
        "schema_version": SCHEMA_VERSION,
        "audio_sha256": audio_sha256,
        "session_name": session_name,
        "updated_at": datetime.now(UTC).isoformat(),
        "labels": dict(sorted(labels.items())),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise
