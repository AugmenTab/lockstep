from typer.testing import CliRunner

import lockstep
from lockstep.cli.app import app


runner = CliRunner()


def test_help_exits_zero() -> None:
    result = runner.invoke(app, ["--help"])
    assert result.exit_code == 0
    assert "Lockstep" in result.output


def test_version_reports_canonical_version() -> None:
    result = runner.invoke(app, ["--version"])
    assert result.exit_code == 0
    assert lockstep.__version__ in result.output


def test_package_import_exposes_version() -> None:
    assert isinstance(lockstep.__version__, str)
    assert lockstep.__version__
