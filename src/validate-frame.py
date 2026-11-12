"""Validate one bounded UTF-8 JSON frame supplied by co_proc__validate_frame.

The zsh entry point enforces the byte/newline limits before calling this helper.
Validation never emits or rewrites the frame; successful callers keep its bytes.
Only Python's standard library is required.
"""

import json
import sys
from decimal import Decimal, DecimalException


def unique_object(pairs):
    """Reject ambiguous keys at every depth, after JSON escape decoding."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate object key")
        result[key] = value
    return result


def reject_constant(value):
    # Python otherwise accepts JavaScript NaN and Infinity, which are not JSON.
    raise ValueError("non-JSON numeric constant")


def validate(frame):
    value = json.loads(
        frame.decode("utf-8"),
        object_pairs_hook=unique_object,
        parse_constant=reject_constant,
        parse_float=Decimal,
    )
    if (
        not isinstance(value, dict)
        or type(value.get("version")) is not int
        or value["version"] != 1
        or not isinstance(value.get("type"), str)
        or not value["type"]
        or not isinstance(value.get("id"), str)
        or not value["id"]
    ):
        raise ValueError("invalid root envelope")

    # json.loads accepts lone escaped surrogates. They are not Unicode scalar
    # values and cannot round-trip as UTF-8. Check both keys and payload strings.
    pending = [value]
    while pending:
        item = pending.pop()
        if isinstance(item, str):
            item.encode("utf-8")
        elif isinstance(item, dict):
            pending.extend(item.keys())
            pending.extend(item.values())
        elif isinstance(item, list):
            pending.extend(item)


def main():
    try:
        validate(sys.stdin.buffer.read())
    except (ValueError, UnicodeError, RecursionError, DecimalException):
        print(
            "co-proc: frame must be a UTF-8 JSON object with integer version 1, "
            "non-empty string type and id, and no duplicate keys",
            file=sys.stderr,
        )
        return 65
    return 0


if __name__ == "__main__":
    sys.exit(main())
