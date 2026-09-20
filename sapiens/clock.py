"""Shared UTC clock with no application dependencies."""
from datetime import datetime, timezone


def utcnow():
    return datetime.now(timezone.utc)
