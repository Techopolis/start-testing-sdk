# wxPython integration

Follow the complete setup in [Python integration](python.md). The runnable
reference is `samples/python-wx/demo.py`.

`WxIntegration(frame, reporter)` subscribes to reportable incidents and presents
native alerts. `show_reporter()` opens a manual form. `recover_previous_crashes()`
can be scheduled after the main frame is visible. `close()` unsubscribes callbacks.
The form offers diagnostics preview, explicit review, internal fields only for
current tester capabilities, automatic log attachments and attachment retry.

Optional ChatGPT controls require the chatgpt extra and an explicitly supplied
ChatGPTAuth instance. Sign-in and AI drafting are user actions. Neither is needed
for ordinary reporting.

Two native smoke tests passed on macOS with RUN_WX_TESTS=1. They exercise tester
submission and anonymous field restrictions. Windows runtime and screen-reader
behavior have not yet been validated. Modal dialogs and server work should be
integrated with your application's lifecycle; always create wx controls on its
UI thread.
