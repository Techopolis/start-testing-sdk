from __future__ import annotations

import hashlib
import io
import json
import zipfile
from dataclasses import asdict, dataclass
from pathlib import Path

from ..models import SCHEMA_VERSION, EventType, Incident, encode
from ..privacy import Redactor
from .services import Upload


@dataclass(frozen=True)
class DiagnosticBundle:
    incident_id: str
    uploads: tuple[Upload, ...]
    schema_version: int = SCHEMA_VERSION

    @property
    def byte_size(self) -> int:
        return sum(len(u.data) for u in self.uploads)

    def preview(self) -> str:
        return "\n\n".join(
            f"{u.name} ({len(u.data)} bytes)\n" + u.data.decode("utf-8", errors="replace")
            for u in self.uploads
        )

    def zip_bytes(self) -> bytes:
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
            for upload in self.uploads:
                archive.writestr(upload.name, upload.data)
        return stream.getvalue()

    @classmethod
    def from_incident(
        cls,
        incident: Incident,
        redactor: Redactor,
        *,
        full_logs: bool,
        restricted: bool = False,
        max_bytes: int = 4_000_000,
    ) -> DiagnosticBundle:
        def serialized(value: object) -> bytes:
            return encode(redactor.clean(value)).encode()

        if restricted:
            # Customer diagnostics are an allowlist: no developer messages, traces,
            # session identifiers, internal fields, or breadcrumbs.
            info = {
                "incident_id": incident.incident_id,
                "timestamp": incident.timestamp,
                "severity": incident.severity,
                "schema_version": SCHEMA_VERSION,
            }
            build = asdict(incident.build_info)
            build.pop("commit")
            build.pop("build")
            uploads = [
                Upload(
                    "incident.json",
                    "application/json",
                    serialized(info),
                    "Minimal incident information",
                ),
                Upload(
                    "environment.json",
                    "application/json",
                    serialized(build),
                    "App version and platform",
                ),
            ]
        else:
            events = [e for e in incident.events if full_logs or not e.full_only]
            info = incident.to_dict()
            if not full_logs:
                info["full_log_range"] = []
            uploads = [
                Upload(
                    "incident.json", "application/json", serialized(info), "Frozen incident details"
                ),
                Upload(
                    "environment.json",
                    "application/json",
                    serialized(asdict(incident.build_info)),
                    "Build and platform",
                ),
                Upload(
                    "breadcrumbs.jsonl",
                    "application/x-ndjson",
                    b"".join(
                        serialized(e.to_dict()) + b"\n"
                        for e in events
                        if e.type == EventType.BREADCRUMB
                    ),
                    "Recent breadcrumbs",
                ),
            ]
            if full_logs:
                text = "\n".join(encode(redactor.clean(e.to_dict())) for e in events)
                uploads.append(
                    Upload(
                        "dev-logs.txt",
                        "text/plain",
                        text.encode(),
                        "Relevant developer logs",
                        "attach_full_logs",
                    )
                )
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "incident_id": incident.incident_id,
            "files": [
                {"name": u.name, "bytes": len(u.data), "sha256": hashlib.sha256(u.data).hexdigest()}
                for u in uploads
            ],
        }
        uploads.insert(
            0,
            Upload(
                "manifest.json",
                "application/json",
                encode(manifest).encode(),
                "Diagnostic bundle manifest",
            ),
        )
        bundle = cls(incident.incident_id, tuple(uploads))
        if bundle.byte_size > max_bytes:
            raise ValueError("Diagnostic bundle exceeds size limit; reduce capture limits")
        return bundle


def selected_attachment(
    path: Path, description: str, redactor: Redactor, max_bytes: int = 5_000_000
) -> Upload:
    """Read only a user-selected regular file; never follow a symlink."""
    import os
    import stat

    name = path.name
    if not name or name in {".", ".."} or any(c in name for c in ("/", "\\", "\x00")):
        raise ValueError("Invalid attachment name")
    types = {
        ".txt": "text/plain",
        ".log": "text/plain",
        ".json": "application/json",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
    }
    content_type = types.get(path.suffix.lower())
    if content_type is None or not description.strip():
        raise ValueError("Select a text, JSON, PNG, or JPEG file and describe it")
    if path.is_symlink():
        raise ValueError("Symlink attachments are not supported")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("Attachment must be a regular file")
        data = stream.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise ValueError("Attachment exceeds size limit")
    if content_type.startswith("text/"):
        data = redactor.text(data.decode("utf-8")).encode()
    elif content_type == "application/json":
        data = encode(redactor.clean(json.loads(data))).encode()
    elif content_type == "image/png" and not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Invalid PNG signature")
    elif content_type == "image/jpeg" and not data.startswith(b"\xff\xd8\xff"):
        raise ValueError("Invalid JPEG signature")
    # Image pixels and metadata cannot be regex-redacted. UI requires explicit review.
    return Upload(
        redactor.text(name), content_type, data, redactor.text(description), "attach_files"
    )
