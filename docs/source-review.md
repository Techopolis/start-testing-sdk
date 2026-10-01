# Sources and attribution

Original SDK code was authored in this repository. No proprietary implementation
was copied. Existing neighboring Start-testing and Start-Testing-iOS repositories
were inspected read-only to understand issue fields, SDK event ingestion and
attachment flow. [Backend contracts](backend-contract.md) distinguishes observed
behavior from proposed SDK interfaces.

Official references used during implementation:

- [Python logging](https://docs.python.org/3/library/logging.html),
  [sys hooks](https://docs.python.org/3/library/sys.html#sys.excepthook), and
  [threading hooks](https://docs.python.org/3/library/threading.html#threading.excepthook)
- [PyInstaller runtime metadata](https://pyinstaller.org/en/stable/runtime-information.html)
- [wxPython Dialog](https://docs.wxpython.org/wx.Dialog.html) and
  [CallAfter](https://docs.wxpython.org/wx.functions.html#wx.CallAfter)
- [Windows native dialogs](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/dialogs-and-flyouts/dialogs)
- [Apple automated accessibility audits, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10035/)
- Public StoreKit Swift interface shipped in the installed Xcode SDK, including
  AppTransaction.shared and environment. Distribution inference remains a hint.
- [OpenAI contracts](chatgpt.md) for OAuth and optional drafting
- [GitHub Python action](https://github.com/actions/setup-python) and
  [.NET action](https://github.com/actions/setup-dotnet) for CI

The platform behavior actually verified locally is listed in
[verification](verification.md). Documentation claims are not substituted for
runtime evidence. Dependencies retain their own licenses. See NOTICE.
