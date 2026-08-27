import hashlib
import json
from collections import Counter, defaultdict
from dataclasses import dataclass
from itertools import permutations
from pathlib import Path


@dataclass(frozen=True)
class Span:
    speaker: str
    start: float
    end: float


@dataclass(frozen=True)
class Assignment:
    speaker: str | None
    dominant_seconds: float
    total_speaker_seconds: float
    material_speakers: int

    @property
    def purity(self) -> float | None:
        if self.total_speaker_seconds == 0:
            return None
        return self.dominant_seconds / self.total_speaker_seconds


@dataclass(frozen=True)
class Run:
    name: str
    source: Path
    spans: tuple[Span, ...]


@dataclass(frozen=True)
class Session:
    path: Path
    audio: Path
    transcript: dict
    audio_sha256: str

    @property
    def remote_segments(self) -> list[dict]:
        return [segment for segment in self.transcript["segments"] if source(segment) == "system"]


def source(segment: dict) -> str | None:
    voice_id = segment.get("voice_id")
    return voice_id.split(":", 1)[0] if voice_id else None


def load_session(path: Path) -> Session:
    metadata = read_json(path / ".quill" / "meta.json")
    transcript = read_json(path / ".quill" / "transcript.json")
    audio = resolve_session_file(path, metadata["files"]["system"])
    return Session(path=path, audio=audio, transcript=transcript, audio_sha256=sha256(audio))


def load_run(name: str, path: Path) -> Run:
    data = read_json(path)
    spans = []
    for item in data.get("segments", []):
        speaker = item.get("speakerId", item.get("speakerIndex"))
        if speaker is None:
            raise ValueError(f"{path}: segment has no speakerId or speakerIndex")
        start = float(item["startTimeSeconds"])
        end = float(item["endTimeSeconds"])
        if end <= start:
            raise ValueError(f"{path}: invalid span {start} to {end}")
        spans.append(Span(speaker=str(speaker), start=start, end=end))
    spans.sort(key=lambda span: (span.start, span.end, span.speaker))
    return Run(name=name, source=path, spans=tuple(spans))


def assign(segment: dict, spans: tuple[Span, ...]) -> Assignment:
    start = segment["start_ms"] / 1000
    end = segment["end_ms"] / 1000
    overlaps = defaultdict(float)
    for span in spans:
        if span.start >= end:
            break
        shared = min(end, span.end) - max(start, span.start)
        if shared > 0:
            overlaps[span.speaker] += shared
    ordered = sorted(overlaps.items(), key=lambda item: (-item[1], item[0]))
    if not ordered:
        return Assignment(None, 0, 0, 0)
    material = sum(seconds >= 0.5 for _, seconds in ordered)
    return Assignment(ordered[0][0], ordered[0][1], sum(overlaps.values()), material)


def summarize(assignments: list[Assignment], span_count: int) -> dict:
    counts = Counter(assignment.speaker for assignment in assignments)
    return {
        "span_count": span_count,
        "assigned_counts": dict(sorted(counts.items(), key=lambda item: str(item[0]))),
        "unassigned": counts[None],
        "material_multi": sum(assignment.material_speakers > 1 for assignment in assignments),
        "low_purity": sum(
            assignment.purity is not None and assignment.purity < 0.8 for assignment in assignments
        ),
    }


def score(
    segments: list[dict], assignments: list[Assignment], annotations: dict[str, str]
) -> dict | None:
    labeled = [
        (segment, assignment, annotations.get(segment_key(segment)))
        for segment, assignment in zip(segments, assignments, strict=True)
        if annotations.get(segment_key(segment)) in {"A", "B", "C"}
    ]
    if not labeled:
        return None

    speakers = sorted(
        {assignment.speaker for _, assignment, _ in labeled if assignment.speaker is not None}
    )
    human_labels = ("A", "B", "C")
    mapping_size = min(len(speakers), len(human_labels))
    best_mapping: dict[str, str] = {}
    best_correct_seconds = -1.0
    for selected_speakers in permutations(speakers, mapping_size):
        for selected_labels in permutations(human_labels, mapping_size):
            mapping = dict(zip(selected_speakers, selected_labels, strict=True))
            correct_seconds = sum(
                (segment["end_ms"] - segment["start_ms"]) / 1000
                for segment, assignment, human_label in labeled
                if assignment.speaker is not None and mapping.get(assignment.speaker) == human_label
            )
            if correct_seconds > best_correct_seconds:
                best_mapping = mapping
                best_correct_seconds = correct_seconds

    total_seconds = sum(
        (segment["end_ms"] - segment["start_ms"]) / 1000 for segment, _, _ in labeled
    )
    correct_rows = sum(
        assignment.speaker is not None and best_mapping.get(assignment.speaker) == human_label
        for _, assignment, human_label in labeled
    )
    return {
        "labeled_rows": len(labeled),
        "duration_accuracy": best_correct_seconds / total_seconds if total_seconds else 0,
        "row_accuracy": correct_rows / len(labeled),
        "mapping": best_mapping,
    }


def segment_key(segment: dict) -> str:
    text_hash = hashlib.sha256(segment["text"].encode()).hexdigest()[:12]
    return f"{segment['start_ms']}:{segment['end_ms']}:{text_hash}"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_session_file(session: Path, relative: str) -> Path:
    candidate = (session / relative).resolve()
    if not candidate.is_relative_to(session.resolve()):
        raise ValueError(f"session file escapes session directory: {relative}")
    if not candidate.is_file():
        raise FileNotFoundError(candidate)
    return candidate


def read_json(path: Path) -> dict:
    with path.open() as handle:
        return json.load(handle)
