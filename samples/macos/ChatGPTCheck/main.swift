import Foundation
import StartTestingChatGPT
import StartTestingCore

// A live check of ChatGPT sign-in and drafting. It opens the default browser,
// waits for you to approve, then lists models and asks for one short draft.
// Credentials stay in this Mac's Keychain. Pass "disconnect" to remove them.
func say(_ text: String) {
  print(text)
  fflush(stdout)
}
do {
  let auth = try ChatGPTAuth.standard(
    appName: "Start Testing SDK Sample", keychainService: "net.starttesting.sdk.sample.ChatGPT")
  if CommandLine.arguments.contains("disconnect") {
    try await auth.disconnect()
    say("Disconnected. ChatGPT credentials were removed from this Mac.")
    exit(0)
  }
  var account = await auth.active
  if let account {
    say("Step 1 of 3 passed: already signed in as \(account.email).")
  } else {
    say("Step 1 of 3: opening your browser for ChatGPT sign-in. Approve it there. Waiting up to 5 minutes.")
    let previous = await auth.connections.first?.clientId
    account = try await auth.signIn(clientID: previous, timeout: 300)
    say("Step 1 of 3 passed: signed in as \(account!.email).")
  }
  guard let account, account.planEnabled else {
    say("FAILED: sign-in worked, but ChatGPT did not grant plan use, so drafting is unavailable.")
    exit(1)
  }
  let provider = ChatGPTProvider(auth: auth, connection: account)
  let models = try await provider.models()
  say("Step 2 of 3 passed: \(models.count) models available: " + models.map(\.displayName).joined(separator: ", "))
  guard let model = models.first else {
    say("FAILED: no models are available to this account.")
    exit(1)
  }
  let context = Data(
    #"{"error_type":"SampleError","message":"Save button does nothing","tester_notes":"Pressed Save in Preferences twice. Nothing was saved and no error appeared.","events":[{"type":"breadcrumb","message":"Opened Preferences"},{"type":"error","message":"Save failed with code 12"}]}"#
      .utf8)
  let draft = try await provider.draft(sanitizedContext: context, model: model.slug)
  say("Step 3 of 3 passed: draft received from \(model.displayName).")
  say("Title: " + draft.title)
  say("Summary: " + draft.summary)
  say("ALL CHECKS PASSED. ChatGPT sign-in and drafting work with the real service.")
} catch is CancellationError {
  say("FAILED: sign-in was cancelled or denied in the browser.")
  exit(1)
} catch {
  say("FAILED: " + error.localizedDescription)
  exit(1)
}
