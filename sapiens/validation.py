"""Shared request validation, independent of the application service."""
import re


class APIError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def text_field(data, field, maximum):
    value = data.get(field)
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise APIError(400, f"{field} must be nonempty text, at most {maximum} characters")
    return value.strip()


def sapi_name(data):
    value = text_field(data, "name", 24)
    if value != data["name"] or not re.fullmatch(r"[A-Z][A-Za-z0-9_.:#+|()&$^\-]*", value):
        raise APIError(400, "Name must start with A–Z; use letters, numbers, or - _ . : # + | ( ) & $ ^ (no spaces)")
    return value
