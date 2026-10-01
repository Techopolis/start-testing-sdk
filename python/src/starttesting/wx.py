"""Optional native wxPython reporter: install starttesting[wx]."""

try:
    import wx as _wx  # noqa: F401
except ImportError:
    raise ImportError('Install the wx extra: pip install "starttesting[wx]"') from None

from .integrations.wx import ReporterDialog, TextPreview, WxIntegration

__all__ = ["ReporterDialog", "TextPreview", "WxIntegration"]
