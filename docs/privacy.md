# Privacy

Default capture is local and bounded. Upload requires an explicit submission action.
Diagnostic inclusion is separately visible in the reporter. Anonymous customers
receive minimal incident/build metadata when they consent, with no full logs,
internal issue fields, session identifiers, breadcrumbs or stack traces.

The SDK never installs network-body interception, clipboard monitoring, document
scanning, microphone recording, screen recording, database scanning or telemetry
upload. Screenshots are user-selected files in the Python reporter, not automatic
screen capture. The Swift and .NET reporters currently attach SDK-generated files;
additional user-file UI remains outstanding.

Full logs require all three: a configured opt-in, a project policy that allows
them, and a current authenticated tester grant with `attach_full_logs`. Developers
and QA have the same capability checks. Normal collection defaults to warning
and higher plus explicit breadcrumbs. Capture and upload permission are separate.

Redaction runs before events reach buffers/files and when bundles/drafts are
prepared. Submission rechecks against current privacy rules; changed content must
be reviewed again. Keys, registered values, regular expressions, custom redactors,
category suppression, field allowlists and denylists are available. Custom regex
patterns are trusted developer configuration; avoid expensive pathological patterns.

Filtering cannot identify every private value. Register application-specific
sensitive values before recording activity, and never log credentials or private
user content intentionally. Text attachments are filtered; PNG/JPEG contents and
metadata need human inspection. The Python adapter accepts only explicitly
selected regular text, JSON, PNG or JPEG files with size/count limits.

Persistence is opt-in. Defaults: 1 MB per journal segment, four segments, one day
of file retention, ten persisted incidents, and 3 MB per incident. Python and Swift
use private POSIX directories/files. Windows requires per-user local storage with
host-managed ACLs. No cloud backup or cross-device token synchronization is provided.

Changing privacy rules does not retroactively rewrite previously persisted files.
Purge old diagnostics after changing policy. Signing out clears current captured
context; a filesystem failure can prevent deletion and increments the diagnostic
storage failure counter. Local disk encryption and account security remain the
embedding application's deployment responsibilities.
