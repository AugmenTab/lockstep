import importlib

import pytest


ARCHITECTURE_PACKAGES = (
    "lockstep.agents",
    "lockstep.context",
    "lockstep.domain",
    "lockstep.git",
    "lockstep.persistence",
    "lockstep.process",
    "lockstep.reporting",
    "lockstep.state",
    "lockstep.verification",
)


@pytest.mark.parametrize("module_name", ARCHITECTURE_PACKAGES)
def test_architecture_package_is_importable_and_documented(module_name: str) -> None:
    module = importlib.import_module(module_name)

    assert module.__doc__ is not None
    assert module.__doc__.strip()
