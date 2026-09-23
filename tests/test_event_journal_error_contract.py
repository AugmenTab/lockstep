from lockstep.persistence import JournalIntegrityError


def test_journal_integrity_error_exposes_reason_and_line_number() -> None:
    error = JournalIntegrityError("invalid JSON", line_number=2)

    assert error.reason == "invalid JSON"
    assert error.line_number == 2
    assert str(error) == "event journal integrity error at line 2: invalid JSON"


def test_journal_integrity_error_without_line_number_exposes_reason() -> None:
    error = JournalIntegrityError("journal ends with an incomplete event")

    assert error.reason == "journal ends with an incomplete event"
    assert error.line_number is None
    assert str(error) == "event journal integrity error: journal ends with an incomplete event"
