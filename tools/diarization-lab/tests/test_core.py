import json

from app.core import Assignment, Span, assign, load_run, resolve_session_file, score, segment_key


def test_dominant_assignment_reports_ambiguity():
    segment = {"start_ms": 1_000, "end_ms": 5_000, "text": "Hello"}
    assignment = assign(segment, (Span("A", 1.0, 4.0), Span("B", 3.0, 5.0)))

    assert assignment.speaker == "A"
    assert assignment.dominant_seconds == 3
    assert assignment.total_speaker_seconds == 5
    assert assignment.material_speakers == 2
    assert assignment.purity == 0.6


def test_load_run_accepts_both_fluidaudio_schemas(tmp_path):
    path = tmp_path / "run.json"
    path.write_text(
        json.dumps(
            {
                "segments": [
                    {"speakerIndex": 0, "startTimeSeconds": 0, "endTimeSeconds": 1},
                    {"speakerId": "S2", "startTimeSeconds": 1, "endTimeSeconds": 2},
                ]
            }
        )
    )

    run = load_run("model", path)

    assert [span.speaker for span in run.spans] == ["0", "S2"]


def test_segment_key_changes_with_text():
    first = {"start_ms": 1, "end_ms": 2, "text": "One"}
    second = {"start_ms": 1, "end_ms": 2, "text": "Two"}

    assert segment_key(first) != segment_key(second)


def test_session_file_cannot_escape(tmp_path):
    outside = tmp_path.parent / "outside.m4a"
    outside.write_bytes(b"audio")

    try:
        resolve_session_file(tmp_path, "../outside.m4a")
    except ValueError as error:
        assert "escapes" in str(error)
    else:
        raise AssertionError("expected escaped path to fail")


def test_score_finds_best_anonymous_speaker_mapping():
    segments = [
        {"start_ms": 0, "end_ms": 1_000, "text": "One"},
        {"start_ms": 1_000, "end_ms": 3_000, "text": "Two"},
        {"start_ms": 3_000, "end_ms": 4_000, "text": "Three"},
        {"start_ms": 4_000, "end_ms": 5_000, "text": "Four"},
    ]
    assignments = [
        Assignment("model-2", 1, 1, 1),
        Assignment("model-1", 2, 2, 1),
        Assignment("model-2", 1, 1, 1),
        Assignment(None, 0, 0, 0),
    ]
    annotations = {
        segment_key(segments[0]): "A",
        segment_key(segments[1]): "B",
        segment_key(segments[2]): "A",
        segment_key(segments[3]): "C",
    }

    result = score(segments, assignments, annotations)

    assert result == {
        "labeled_rows": 4,
        "duration_accuracy": 0.8,
        "row_accuracy": 0.75,
        "mapping": {"model-1": "B", "model-2": "A"},
    }


def test_score_ignores_non_identity_labels():
    segment = {"start_ms": 0, "end_ms": 1_000, "text": "One"}

    assert score([segment], [Assignment("0", 1, 1, 1)], {segment_key(segment): "Mixed"}) is None
