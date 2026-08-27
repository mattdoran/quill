import os
from pathlib import Path

import click

from .web import create_app


@click.group()
def cli():
    pass


@cli.command()
@click.argument("session", type=click.Path(path_type=Path, exists=True, file_okay=False))
@click.option(
    "runs",
    "--run",
    multiple=True,
    metavar="NAME=JSON",
    help="FluidAudio diarization result to compare. May be repeated.",
)
@click.option("--host", default="127.0.0.1", show_default=True)
@click.option("--port", default=5062, show_default=True, type=click.IntRange(1, 65535))
@click.option("--debug", is_flag=True)
def serve(session: Path, runs: tuple[str, ...], host: str, port: int, debug: bool):
    home = Path(os.environ.get("QUILL_DIARIZATION_LAB_HOME", "devdata")).resolve()
    app = create_app(session.resolve(), parse_runs(runs), home)
    click.echo(f"Session: {session.resolve()}")
    click.echo(f"Annotations: {app.config['ANNOTATION_PATH']}")
    click.echo(f"Open http://{host}:{port}")
    app.run(host=host, port=port, debug=debug)


def parse_runs(values: tuple[str, ...]) -> dict[str, Path]:
    result = {}
    for value in values:
        name, separator, path = value.partition("=")
        if not separator or not name.strip() or not path.strip():
            raise click.BadParameter(f"expected NAME=JSON, got {value!r}", param_hint="--run")
        if name in result:
            raise click.BadParameter(f"duplicate run name {name!r}", param_hint="--run")
        resolved = Path(path).expanduser().resolve()
        if not resolved.is_file():
            raise click.BadParameter(f"run does not exist: {resolved}", param_hint="--run")
        result[name] = resolved
    return result


if __name__ == "__main__":
    cli()
