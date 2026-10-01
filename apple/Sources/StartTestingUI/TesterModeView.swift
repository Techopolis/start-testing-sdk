import SwiftUI

/// The welcome screen for testers. It is reached through a hidden gesture, so people
/// who are not testers never see it. It explains tester mode and offers sign-in.
public struct TesterModeView: View {
  private let isOn: @MainActor () -> Bool
  private let signIn: @MainActor () async -> String
  private let signOut: @MainActor () async -> String
  @Environment(\.dismiss) private var dismiss
  @State private var on = false
  @State private var busy = false
  @State private var status = ""
  @AccessibilityFocusState private var statusFocused: Bool
  /// `signIn` and `signOut` return the message to read out when they finish.
  public init(
    isOn: @escaping @MainActor () -> Bool, signIn: @escaping @MainActor () async -> String,
    signOut: @escaping @MainActor () async -> String
  ) {
    self.isOn = isOn
    self.signIn = signIn
    self.signOut = signOut
  }
  public var body: some View {
    NavigationStack {
      Form {
        Section("Welcome to Tester Mode") {
          Text(
            "Tester mode is for people who test this app for the team. It lets you report issues with logs attached, so the team can see what went wrong."
          ).fixedSize(horizontal: false, vertical: true)
          Text(
            "If you are not a tester, you don't need this. Close this screen and keep using the app as usual."
          ).fixedSize(horizontal: false, vertical: true)
        }
        Section {
          if on {
            Text("Tester mode is on. You are signed in to Start Testing.")
            Button("Sign Out and Leave Tester Mode", role: .destructive) {
              run { await signOut() }
            }
          } else {
            Text("To turn on tester mode, sign in with your Start Testing account.")
              .fixedSize(horizontal: false, vertical: true)
            Button("Sign In to Start Testing") { run { await signIn() } }
              .accessibilityHint("Opens secure sign-in for your Start Testing account")
            Button("Not Now") { dismiss() }
          }
        }
        if !status.isEmpty || busy {
          Section {
            if !status.isEmpty {
              Text(status).accessibilityFocused($statusFocused)
                .fixedSize(horizontal: false, vertical: true)
            }
            if busy { ProgressView("Working") }
          }
        }
      }
      .disabled(busy)
      .navigationTitle("Tester Mode")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      }
      .onAppear { on = isOn() }
    }.frame(minWidth: 300, minHeight: 360)
  }
  private func run(_ action: @escaping @MainActor () async -> String) {
    busy = true
    Task {
      let message = await action()
      on = isOn()
      busy = false
      status = message
      statusFocused = true
    }
  }
}

private struct TesterModeGesture: ViewModifier {
  let activations: Int
  let isOn: @MainActor () -> Bool
  let signIn: @MainActor () async -> String
  let signOut: @MainActor () async -> String
  @State private var count = 0
  @State private var first = Date.distantPast
  @State private var presented = false
  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onTapGesture { activate() }
      // VoiceOver and Switch Control reach the same counter by activating the element.
      .accessibilityAction { activate() }
      .sheet(isPresented: $presented) {
        TesterModeView(isOn: isOn, signIn: signIn, signOut: signOut)
      }
  }
  private func activate() {
    let now = Date()
    // Generous, because each VoiceOver activation is itself a double tap.
    if now.timeIntervalSince(first) > 30 {
      first = now
      count = 0
    }
    count += 1
    if count >= activations {
      count = 0
      first = .distantPast
      presented = true
    }
  }
}
extension View {
  /// Opens the tester mode screen after this view is activated several times in a
  /// row. Attach it to something unremarkable, such as the version number.
  public func startTestingTesterMode(
    activations: Int = 7, isOn: @escaping @MainActor () -> Bool,
    signIn: @escaping @MainActor () async -> String,
    signOut: @escaping @MainActor () async -> String
  ) -> some View {
    modifier(
      TesterModeGesture(activations: activations, isOn: isOn, signIn: signIn, signOut: signOut))
  }
}
