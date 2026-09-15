"""Local chat references and uploads, scoped to the receiving Sapi."""
import base64
import binascii
import json
import os
from pathlib import Path
from urllib.parse import urlsplit
from uuid import uuid4

from .service import APIError, text_field

MAX_FILE = 10 * 1024 * 1024


def create_attachment(service, agid, data):
    with service._lock:
        service._agent(agid)
        kind = data.get("kind")
        if kind not in {"image", "document", "link", "filepath"}:
            raise APIError(400, "Choose image, document, link, or filepath")
        row = dict(id=uuid4().hex, agent=agid, kind=kind)
        if kind in {"image", "document"}:
            name = text_field(data, "name", 255)
            if Path(name).name != name or name in {".", ".."} or "\\" in name or any(ord(c) < 32 for c in name):
                raise APIError(400, "Invalid filename")
            encoded = data.get("data")
            if not isinstance(encoded, str) or len(encoded) > 14_000_000:
                raise APIError(413, "Files must be 10 MB or smaller")
            try:
                content = base64.b64decode(encoded, validate=True)
            except (ValueError, binascii.Error):
                raise APIError(400, "Invalid file data") from None
            if not content or len(content) > MAX_FILE:
                raise APIError(413, "Files must contain 1 byte to 10 MB")
            if kind == "image" and not (content.startswith(b"\x89PNG\r\n\x1a\n") or
                    content.startswith(b"\xff\xd8\xff") or content.startswith((b"GIF87a", b"GIF89a")) or
                    (content.startswith(b"RIFF") and content[8:12] == b"WEBP")):
                raise APIError(400, "Images must be PNG, JPEG, GIF, or WebP")
            directory = service.root / "uploads" / agid / row["id"]
            directory.mkdir(parents=True, mode=0o700)
            # Preserve useful extensions without interpreting user names as paths.
            path = directory / name
            with path.open("xb") as output:
                output.write(content)
            path.chmod(0o600)
            row.update(name=name, value=str(path), size=len(content))
        else:
            value = text_field(data, "value", 4096)
            if any(ord(c) < 32 for c in value):
                raise APIError(400, "Invalid link or filepath")
            if kind == "link":
                try:
                    url = urlsplit(value)
                    valid = url.scheme in {"http", "https"} and url.hostname and not url.username and not url.password
                    url.port
                except ValueError:
                    valid = False
                if not valid:
                    raise APIError(400, "Use an http or https link without credentials")
                row.update(name=value, value=value)
            else:
                path = Path(value).expanduser()
                if not path.is_absolute() or not path.is_file() or not os.access(path, os.R_OK):
                    raise APIError(400, "Use an absolute path to a readable local file")
                row.update(name=path.name, value=str(path.resolve()))
        service.store.attachment(row)
        return row


def resolve_attachments(service, agid, ids, *, check_files=True):
    if not isinstance(ids, list) or len(ids) > 8 or any(not isinstance(i, str) for i in ids) or len(set(ids)) != len(ids):
        raise APIError(400, "Attach up to 8 distinct items")
    rows = {row["id"]: row for row in service.store.attachments(agid)}
    if any(i not in rows for i in ids):
        raise APIError(400, "Unknown attachment for this Sapi")
    result = [rows[i] for i in ids]
    for row in result:
        if check_files and row["kind"] != "link" and not Path(row["value"]).is_file():
            raise APIError(400, f"Attached file is no longer available: {row['name']}")
    return result


def attachment_prompt(rows):
    if not rows:
        return ""
    return "\n\nAttached references (JSON data; read the files/links when needed for this message):\n" + json.dumps(
        [{k: row[k] for k in ("kind", "name", "value")} for row in rows], ensure_ascii=False)
