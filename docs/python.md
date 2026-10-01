# Add the Python SDK to an app

Status: local alpha. Nothing has been published to PyPI. Use the source path.

## 1. Install into your app's virtual environment

Run this using the Python interpreter that runs your app:

```bash
python -m pip install -e path/to/start-testing-sdk/python
```

For a wxPython app, install the native UI extra:

```bash
python -m pip install -e 'path/to/start-testing-sdk/python[wx]'
```

The editable install reads this checkout. Moving or deleting it breaks the install.
For a copied installation, omit `-e`. Core installation has no external dependencies.

## 2. Configure once at application startup

```python
import starttesting

client = starttesting.configure(
    project_id="your-public-project-id",
    environment="beta",
)
starttesting.breadcrumb("Opened Preferences")

try:
    save_preferences()
except Exception as error:
    starttesting.reportable_error(
        error, user_message="Unable to save preferences"
    )
```

Replace `save_preferences()` with your app's operation. Use `production` in released
production builds. Call `client.close()` when shutting down. This setup captures
locally in memory; it does not show a report form or send reports by itself.

## 3. Add native wx reporting with the local mock

After creating `wx.App` and your frame, configure these objects once. If using this
example, replace the earlier configuration with it.

```python
from starttesting import Client, Options
from starttesting.auth.mock import MockBackend
from starttesting.reporting.reporter import Reporter
from starttesting.wx import WxIntegration

backend = MockBackend()
client = Client(
    "proj_demo", environment="beta", options=Options(full_logs=True),
    project_service=backend, authorization_service=backend,
)
reporter = Reporter(client, issues=backend, feedback=backend, attachments=backend)
integration = WxIntegration(frame, reporter)

# A demonstration login, not production authentication:
client.authenticate(backend)
client.breadcrumb("Opened Preferences")
client.reportable_error(
    RuntimeError("Example failure"), user_message="Unable to save preferences"
)

# Bind this to a Help menu item or a button:
# integration.show_reporter()
```

Use `integration.close()` and then `client.close()` on shutdown. UI setup and
presentation must run on the wx UI thread. See the complete runnable
[wx sample](../samples/python-wx/demo.py), including logging, storage and shutdown.

## 4. Connect real reports

Replace `MockBackend` with implementations of the authentication, authorization,
project, issue, feedback and attachment protocols. See [backend contracts](backend-contract.md).
No production adapter is included yet. Changing the project ID alone does not
connect this alpha to the Start Testing service. Never ship mock authentication.

Full developer logs require all three: explicit app opt-in, project configuration,
and a current tester capability grant. The reporter prepares attachments, presents
review and consent, and retries failed uploads against the same created issue.

## Verify locally

```bash
cd path/to/start-testing-sdk
.venv/bin/python samples/python-cli/demo.py --submit
.venv/bin/python samples/python-wx/demo.py
```

The CLI prints a local mock report ID. In wx, sign in as Mock Tester, perform test
actions, trigger an error, inspect diagnostics, and submit. No report reaches the
real service in these demonstrations.
