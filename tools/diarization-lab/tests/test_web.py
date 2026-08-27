import json
import re

from app.web import create_app


def fixture(tmp_path):
    session = tmp_path / "session"
    internal = session / ".quill"
    source = session / "Source Audio"
    internal.mkdir(parents=True)
    source.mkdir()
    (source / "Remote.m4a").write_bytes(b"audio")
    (internal / "meta.json").write_text(
        json.dumps({"files": {"system": "Source Audio/Remote.m4a"}})
    )
    (internal / "transcript.json").write_text(
        json.dumps(
            {
                "segments": [
                    {
                        "voice_id": "system:1",
                        "speaker": "Them",
                        "start_ms": 0,
                        "end_ms": 1_000,
                        "text": "Remote words",
                    }
                ]
            }
        )
    )
    run = tmp_path / "run.json"
    run.write_text(
        json.dumps({"segments": [{"speakerIndex": 0, "startTimeSeconds": 0, "endTimeSeconds": 1}]})
    )
    return session, run


def test_real_page_audio_and_annotation_flow(tmp_path):
    session, run = fixture(tmp_path)
    home = tmp_path / "home"
    app = create_app(session, {"sortformer": run}, home)
    client = app.test_client()

    page = client.get("/")
    assert page.status_code == 200
    assert b"Remote words" in page.data
    assert b"sortformer: 0" in page.data
    assert b"Unsaved changes" in page.data
    assert b"Playback continues through following rows" in page.data

    ranged_audio = client.get("/audio", headers={"Range": "bytes=0-1"})
    assert ranged_audio.status_code == 206
    assert ranged_audio.data == b"au"

    label_name = re.search(rb'name="(label:[^"]+)"', page.data).group(1).decode()
    saved = client.post("/annotations", data={label_name: "A"}, follow_redirects=True)
    assert saved.status_code == 200
    assert b"checked" in saved.data
    assert b"100.0%" in saved.data
    assert b"0\xe2\x86\x92A" in saved.data

    rejected = client.post(
        "/annotations", data={label_name: "B"}, headers={"Sec-Fetch-Site": "cross-site"}
    )
    assert rejected.status_code == 403
