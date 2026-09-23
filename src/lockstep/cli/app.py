from typing import Annotated

import typer

from lockstep import __version__


app = typer.Typer(
    name="lockstep",
    help="Lockstep: local-first supervised AI software-development orchestration.",
    no_args_is_help=True,
    add_completion=False,
)


def _version_callback(value: bool) -> None:
    if value:
        typer.echo(__version__)
        raise typer.Exit()


@app.callback()
def main(
    version: Annotated[
        bool,
        typer.Option(
            "--version",
            help="Show the Lockstep version and exit.",
            callback=_version_callback,
            is_eager=True,
        ),
    ] = False,
) -> None:
    """Lockstep command-line interface."""
