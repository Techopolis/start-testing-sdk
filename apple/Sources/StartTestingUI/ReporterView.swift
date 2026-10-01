import StartTestingAuth
import StartTestingChatGPT
import StartTestingCore
import StartTestingDiagnostics
import SwiftUI

public struct ReporterView: View {
  private let reporter: Reporter
  private let incident: Incident?
  private let chatGPT: ChatGPTAuth?
  @State private var aiAllowed = false
  @State private var chatAccount: ChatGPTConnection?
  @State private var chatModels: [ChatGPTModel] = []
  @AppStorage("StartTesting.chatGPTModel") private var chatModel = ""
  @AppStorage("StartTesting.chatGPTAutoDraft") private var chatAutoDraft = false
  @AppStorage(AILogMonitor.enabledKey) private var chatWatchLogs = false
  @Environment(\.dismiss) private var dismiss
  @State private var draft = IssueDraft()
  @State private var mode: UserMode = .productionSupport
  @State private var detailed = false
  @AppStorage("StartTesting.reporterName") private var reporterName = ""
  @AppStorage("StartTesting.reporterEmail") private var reporterEmail = ""
  @State private var diagnosticsOffered = true
  @State private var fields: [FieldDefinition] = []
  @State private var consent = false
  @State private var fullLogs = false
  @State private var busy = true
  @State private var status = "Loading reporting options."
  @State private var review: PreparedReport?
  @State private var preview: PreviewContent?
  @AccessibilityFocusState private var statusFocused: Bool
  public init(reporter: Reporter, incident: Incident? = nil, chatGPT: ChatGPTAuth? = nil) {
    self.reporter = reporter
    self.incident = incident
    self.chatGPT = chatGPT
  }
  public var body: some View {
    NavigationStack {
      Form {
        if detailed {
          TextField("Issue Title", text: $draft.title).accessibilityIdentifier("issue-title")
        }
        TextField(
          detailed ? "Description" : "Describe what happened",
          text: $draft.description, axis: .vertical
        ).lineLimit(3...8)
        if detailed {
          TextField("Expected Behavior", text: $draft.expectedBehavior, axis: .vertical)
          TextField("Actual Behavior", text: $draft.actualBehavior, axis: .vertical)
          TextField("Steps to Reproduce", text: $draft.stepsToReproduce, axis: .vertical)
          ForEach(fields, id: \.key) { field in
            Picker(
              field.label,
              selection: Binding(
                get: { draft.metadata[field.key] ?? "" },
                set: { value in
                  if value.isEmpty {
                    draft.metadata.removeValue(forKey: field.key)
                  } else {
                    draft.metadata[field.key] = value
                  }
                })
            ) {
              Text("Not set").tag("")
              ForEach(field.choices, id: \.self) { Text($0).tag($0) }
            }
          }
        }
        if mode != .authenticatedTester {
          TextField("Your Name (optional)", text: $reporterName)
            .textContentType(.name)
            .accessibilityHint("Shown on the report so the team knows who sent it")
          if !detailed {
            TextField("Your Email (optional)", text: $reporterEmail)
              .textContentType(.emailAddress)
              .autocorrectionDisabled()
              .accessibilityHint("Used only so support can reply to you")
          }
        }
        if !diagnosticsOffered {
          Section {
            Text("This opens a support request. No logs are sent with it.")
          }
        }
        if chatGPT != nil, aiAllowed {
          Section("ChatGPT Drafting") {
            if let chatAccount {
              Text(
                chatAccount.email.isEmpty
                  ? "Connected to ChatGPT." : "Connected to ChatGPT as \(chatAccount.email).")
              if !chatModels.isEmpty {
                Picker("Model", selection: $chatModel) {
                  ForEach(chatModels) { Text($0.displayName).tag($0.slug) }
                }
              }
              Toggle("Let ChatGPT watch the logs for problems", isOn: $chatWatchLogs)
                .accessibilityHint(
                  "When on, new failures this app writes to its own log are sent to ChatGPT in a short redacted summary. System messages are left out. If it finds a problem, you are offered a report it has drafted.")
              Toggle("Draft automatically when an error is reported", isOn: $chatAutoDraft)
                .accessibilityHint(
                  "When on, a short redacted summary of each error is sent to ChatGPT as soon as you open its report")
              Button("Draft with ChatGPT") { Task { await reviewChatContext() } }
                .disabled(chatModel.isEmpty)
                .accessibilityHint(
                  "Shows exactly what will be sent to ChatGPT before anything is sent")
              Button("Disconnect ChatGPT") { Task { await disconnectChat() } }
            } else {
              Text(
                "Optional. Sign in with your own ChatGPT account to draft the report from the captured diagnostics. You review and edit the draft before sending."
              )
              Button("Sign In with ChatGPT") { Task { await connectChat() } }
                .accessibilityHint("Opens ChatGPT sign-in in your browser")
            }
          }
        }
        if diagnosticsOffered {
        Section("Diagnostics") {
          Toggle("Include diagnostic information", isOn: $consent)
          Text(
            fullLogs && consent
              ? "Developer logs will be attached automatically."
              : "Full developer logs will not be attached.")
          Button("View Diagnostics") { Task { await showDiagnostics() } }
        }
        }
        Section {
          Text(status).accessibilityFocused($statusFocused)
          if busy { ProgressView("Working") }
        }
      }
      .disabled(busy || review != nil)
      .navigationTitle(detailed ? "Report Issue" : "Report a Problem")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(busy)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(review == nil ? "Review Report" : "Retry Attachments") {
            Task { await prepareOrRetry() }
          }.disabled(busy)
        }
      }
      .interactiveDismissDisabled(busy)
      .task { await load() }
      .sheet(item: $preview) { item in
        NavigationStack {
          ScrollView { Text(item.text).textSelection(.enabled).padding() }
            .navigationTitle(item.title)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) { Button("Back") { preview = nil } }
              if let context = item.aiContext {
                ToolbarItem(placement: .confirmationAction) {
                  Button("Send to ChatGPT") {
                    preview = nil
                    Task { await draftWithChat(context) }
                  }
                }
              }
              if let report = item.report {
                ToolbarItem(placement: .confirmationAction) {
                  Button("Submit Issue") {
                    preview = nil
                    Task { await submit(report) }
                  }
                }
              }
            }
        }.frame(minWidth: 300, minHeight: 400)
      }
    }
  }
  private func announce(_ message: String) {
    status = message
    statusFocused = true
  }
  private func load() async {
    defer { busy = false }
    do {
      try await reporter.client.revalidate()
      mode = await reporter.client.mode
      fullLogs = await reporter.client.fullLogsEnabled
      detailed = await reporter.client.detailedReports
      fields = mode == .authenticatedTester ? await reporter.client.configuration.fields : []
      let canAttach = await reporter.client.allows("attach_diagnostics")
      let feedbackDiagnostics = await reporter.client.configuration.feedbackDiagnostics
      diagnosticsOffered = detailed || feedbackDiagnostics
      consent = detailed && (mode != .authenticatedTester || canAttach)
      draft.title = incident?.safeMessage ?? ""
      draft.description = incident?.safeMessage ?? ""
      // A problem the AI noticed arrives with its draft already written.
      var prefilled = false
      if let incident, let suggestion = await reporter.client.suggestedDraft(for: incident.incidentId)
      {
        draft = suggestion
        prefilled = true
      }
      aiAllowed = await reporter.aiDraftingAllowed
      if aiAllowed, let chatGPT, let account = await chatGPT.active {
        chatAccount = account
        // The saved connection may have expired; the form stays usable either way.
        try? await loadChatModels(chatGPT, account)
      }
      // The tester opted in once, so an error report arrives with a draft to review.
      if prefilled {
        announce("ChatGPT noticed this in the logs and drafted the report. Review and edit it before submitting.")
        return
      }
      if chatAutoDraft, chatAccount != nil, !chatModel.isEmpty, let incident,
        incident.origin == "error",
        let context = try? await reporter.aiContext(incident: incident, notes: draft.description)
      {
        announce("ChatGPT is drafting this report.")
        await draftWithChat(context)
        return
      }
      announce("Diagnostics captured. Review before submitting.")
    } catch { announce("Reporting options could not be loaded.") }
  }
  private func loadChatModels(_ auth: ChatGPTAuth, _ account: ChatGPTConnection) async throws {
    chatModels = try await ChatGPTProvider(auth: auth, connection: account).models()
    if !chatModels.contains(where: { $0.slug == chatModel }) {
      chatModel = chatModels.first?.slug ?? ""
    }
  }
  private func connectChat() async {
    guard let chatGPT else { return }
    busy = true
    defer { busy = false }
    do {
      let account = try await chatGPT.signIn()
      guard account.planEnabled else {
        announce("ChatGPT signed in, but did not allow plan use. Manual reporting is available.")
        return
      }
      chatAccount = account
      try await loadChatModels(chatGPT, account)
      announce("Connected to ChatGPT.")
    } catch is CancellationError {
      announce("ChatGPT sign-in cancelled. You can keep writing the report yourself.")
    } catch { announce(reporter.client.redactor.text(error.localizedDescription)) }
  }
  private func disconnectChat() async {
    guard let chatGPT else { return }
    busy = true
    defer { busy = false }
    chatAccount = nil
    chatModels = []
    do {
      try await chatGPT.disconnect()
      announce("Disconnected from ChatGPT.")
    } catch {
      announce("ChatGPT was removed from this device, but OpenAI could not confirm it.")
    }
  }
  private func reviewChatContext() async {
    busy = true
    defer { busy = false }
    let captured: Incident
    if let incident { captured = incident } else { captured = await reporter.client.manualIncident() }
    do {
      let context = try await reporter.aiContext(incident: captured, notes: draft.description)
      preview = PreviewContent(
        title: "This will be sent to ChatGPT", text: String(decoding: context, as: UTF8.self),
        aiContext: context)
    } catch { announce("The ChatGPT draft could not be prepared.") }
  }
  private func draftWithChat(_ context: Data) async {
    guard let chatGPT, let chatAccount else { return }
    let wasBusy = busy
    busy = true
    defer { busy = wasBusy }
    do {
      let result = try await reporter.aiDraft(
        provider: ChatGPTProvider(auth: chatGPT, connection: chatAccount), context: context,
        model: chatModel)
      draft.title = String(result.title.prefix(200))
      draft.description = [result.summary, result.relevantDiagnostics, result.possibleHypothesis]
        .filter { !$0.isEmpty }.joined(separator: "\n\n")
      draft.actualBehavior = result.observedBehavior
      draft.expectedBehavior = result.expectedBehavior
      draft.stepsToReproduce = result.reproductionContext
      announce("ChatGPT draft added. Review and edit it before submitting.")
    } catch { announce(reporter.client.redactor.text(error.localizedDescription)) }
  }
  private func showDiagnostics() async {
    let captured: Incident
    if let incident {
      captured = incident
    } else {
      captured = await reporter.client.manualIncident()
    }
    do {
      try await reporter.client.revalidate()
      let unrestricted = await reporter.client.detailedReports
      let subject = await reporter.client.grant?.subject
      guard captured.projectId == reporter.client.projectId,
        captured.testerSubject == nil || captured.testerSubject == subject
      else { throw SDKError.unauthorized }
      let permittedLogs = await reporter.client.fullLogsEnabled
      let bundle = try DiagnosticBundle.create(
        incident: captured, redactor: reporter.client.redactor,
        fullLogs: permittedLogs && captured.testerSubject == subject,
        restricted: !unrestricted)
      preview = PreviewContent(title: "View Diagnostics", text: bundle.preview)
    } catch { announce("Diagnostics could not be displayed.") }
  }
  private func prepareOrRetry() async {
    if let review {
      await submit(review)
      return
    }
    busy = true
    defer { busy = false }
    do {
      var input = draft
      if mode != .authenticatedTester {
        input.metadata = ["reporter": reporterName, "email": detailed ? "" : reporterEmail]
      }
      let prepared = try await reporter.prepare(
        input, incident: incident, diagnosticConsent: consent)
      let text =
        String(decoding: try Wire.encode(prepared.draft), as: UTF8.self) + "\n\n"
        + (prepared.bundle?.preview ?? "No diagnostics selected.")
      preview = PreviewContent(title: "Review before sending", text: text, report: prepared)
    } catch { announce(reporter.client.redactor.text(error.localizedDescription)) }
  }
  private func submit(_ prepared: PreparedReport) async {
    busy = true
    defer { busy = false }
    review = prepared
    do {
      let result = try await reporter.submit(prepared, approval: Reporter.approve(prepared))
      announce(
        result.report.kind == "ticket"
          ? "Support request sent. The team will reply by email if you gave an address."
          : result.complete
            ? "Report \(result.report.reportId) submitted."
              + (prepared.bundle == nil ? "" : " Diagnostics attached.")
            : "Report created. \(result.pending.count) attachments need retry.")
      if result.complete {
        review = nil
        dismiss()
      }
    } catch { announce(reporter.client.redactor.text(error.localizedDescription)) }
  }
}
private struct PreviewContent: Identifiable {
  let id = UUID()
  let title: String
  let text: String
  var report: PreparedReport? = nil
  var aiContext: Data? = nil
}
