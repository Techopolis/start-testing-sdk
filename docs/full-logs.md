# Full logs and automatic attachments

Enable full logs in the client options, then authenticate against the project's
service. The project must allow full logging and the grant must include
attach_full_logs. DEBUG and INFO records are rejected unless that combination is
currently true. QA testers and developers follow identical checks.

An incident keeps its own immutable log window. Later rotation or new activity
cannot change that report. A manual report freezes the recent session window at
prepare time. The reporter derives diagnostic files automatically; the tester does
not select the developer-log file manually.

The tester sees the diagnostic inclusion control and automatic-log status before
submitting. On submission, the issue is created first, then its log and other
selected diagnostic files are attached. A failed attachment returns a partial
result; it never reports complete success. Retry uses the same issue and upload keys.

Collection does not authorize transmission. Production defaults exclude full logs,
and users can submit manual feedback without diagnostics or ChatGPT.
