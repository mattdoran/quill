import json

import pytest

from app.storage import annotation_path, read_annotations, write_annotations


def test_annotations_round_trip(tmp_path):
    path = annotation_path(tmp_path, "abc")
    write_annotations(path, "abc", "session", {"segment": "A"})

    assert read_annotations(path, "abc") == {"segment": "A"}


def test_annotations_reject_wrong_audio(tmp_path):
    path = annotation_path(tmp_path, "abc")
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"schema_version": 1, "audio_sha256": "other", "labels": {}}))

    with pytest.raises(ValueError, match="fingerprint"):
        read_annotations(path, "abc")


def test_annotations_reject_unknown_label(tmp_path):
    path = annotation_path(tmp_path, "abc")

    with pytest.raises(ValueError, match="unsupported"):
        write_annotations(path, "abc", "session", {"segment": "D"})
