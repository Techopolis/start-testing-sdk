import AuthenticationServices
import Foundation
#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Opens the ChatGPT sign-in page. macOS uses the default browser. iOS uses the
/// system sign-in sheet so the app stays in front and its loopback callback keeps
/// listening; the sheet is closed once the callback arrives.
@MainActor
public final class ChatGPTBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?
  public override init() { super.init() }
  public func open(_ url: URL) -> Bool {
    #if os(macOS)
      return NSWorkspace.shared.open(url)
    #else
      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      self.session = session
      return session.start()
    #endif
  }
  public func close() {
    session?.cancel()
    session = nil
  }
  public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if canImport(UIKit)
      return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    #else
      return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    #endif
  }
}

extension ChatGPTAuth {
  /// The standard setup: Keychain storage and the platform's sign-in browser.
  @MainActor
  public static func standard(appName: String, keychainService: String) throws -> ChatGPTAuth {
    let browser = ChatGPTBrowser()
    return try ChatGPTAuth(
      store: ChatGPTKeychainStore(service: keychainService), appName: appName,
      open: { url in await browser.open(url) }, dismiss: { await browser.close() })
  }
}
