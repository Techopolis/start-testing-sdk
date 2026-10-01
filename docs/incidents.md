# Incidents, prompts, and crash recovery

Informational and warning errors record context without prompting. Reportable and
critical errors freeze the current diagnostic window. Fatal events persist when
possible and never attempt to show UI during termination. Each incident binds the
project, session, build, origin, severity, safe message, exception information, and
capturing tester subject when available.

Prompt policies are always, critical_only and manual_only. Repeated identical
failures are deduplicated, and a minimum interval limits different prompts. The
rate-limit table is bounded. Dismiss does not create an issue. View Diagnostics
only opens a local preview. UI adapters marshal prompts to their native UI thread.

Python opt-in exception hooks chain sys.excepthook, threading.excepthook, and an
explicit asyncio loop handler. Uninstall preserves any newer application handler.
Main-thread unhandled exceptions create fatal context; worker and asyncio failures
are reportable because they need not terminate the whole process. The .NET helper
subscribes to unhandled/unobserved exception events without suppressing host behavior.

Crash handling is best effort. SIGKILL, power loss, native memory corruption, Swift
traps and out-of-process termination are not intercepted. Swift does not install
signal or exception interception. If the host can safely identify a fatal event,
it can explicitly record it. Persisted fatal incidents can be recovered on the next
launch. There is no claim of universal crash detection.
