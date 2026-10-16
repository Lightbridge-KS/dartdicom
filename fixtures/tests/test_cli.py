from typer.testing import CliRunner

from dartdicom_fixtures.cli import app

runner = CliRunner()


def test_list_names_every_scenario() -> None:
    result = runner.invoke(app, ["list"])
    assert result.exit_code == 0
    assert "synthetic/ct_signed_explicit_le.dcm" in result.output
    assert "pydicom/CT_small.dcm" in result.output


def test_no_arguments_shows_help() -> None:
    result = runner.invoke(app, [])
    assert "build" in result.output and "check" in result.output
