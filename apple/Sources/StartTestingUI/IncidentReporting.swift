import StartTestingAuth
import StartTestingChatGPT
import StartTestingCore
import StartTestingDiagnostics
import SwiftUI

private struct IncidentReporting: ViewModifier {
  let reporter: Reporter
  let chatGPT: ChatGPTAuth?
  @State private var incident: Incident?
  @State private var alertPresented = false
  @State private var tester = false
  @State private var diagnostics = true
  @State private var sheet: Destination?
  func body(content: Content) -> some View {
    content
      .task {
        await reporter.client.setIncidentHandler { captured in
          Task { @MainActor in
            guard !alertPresented && sheet == nil else { return }
            tester = await reporter.client.detailedReports
            let feedbackDiagnostics = await reporter.client.configuration.feedbackDiagnostics
            diagnostics = tester || feedbackDiagnostics
            incident = captured
            alertPresented = true
          }
        }
        if let recovered = try? await reporter.client.recoveredIncidents().first,
          await reporter.client.shouldPrompt(recovered)
        {
          tester = await reporter.client.detailedReports
          let feedbackDiagnostics = await reporter.client.configuration.feedbackDiagnostics
            diagnostics = tester || feedbackDiagnostics
          incident = recovered
          alertPresented = true
        }
      }
      .onDisappear { Task { await reporter.client.setIncidentHandler(nil) } }
      .alert(diagnostics ? "Diagnostics captured" : "Something went wrong", isPresented: $alertPresented, presenting: incident) { item in
        Button(tester ? "Report Issue" : "Report a Problem") { sheet = .report(item) }
        if diagnostics {
        Button("View Diagnostics") {
          Task {
            guard (try? await reporter.client.revalidate()) != nil else { return }
            let full = await reporter.client.fullLogsEnabled
            let subject = await reporter.client.grant?.subject
            guard item.projectId == reporter.client.projectId,
              item.testerSubject == nil || item.testerSubject == subject else { return }
            let currentTester = await reporter.client.detailedReports
            if let bundle = try? DiagnosticBundle.create(
              incident: item, redactor: reporter.client.redactor,
              fullLogs: full && item.testerSubject == subject, restricted: !currentTester)
            {
              sheet = .diagnostics(bundle.preview)
            }
          }
        }
        }
        Button("Dismiss", role: .cancel) {
          if item.severity == .fatal { try? reporter.client.store?.acknowledge(item.incidentId) }
        }
      } message: { item in
        Text(
          item.severity == .fatal
            ? "The app closed unexpectedly during the previous session. Would you like to send a diagnostic report?"
            : tester
              ? "Something went wrong. Start Testing captured diagnostic information for this incident. Would you like to report it?"
              : diagnostics
                ? "Something went wrong. Would you like to send diagnostic information to support?"
                : "Something went wrong. Would you like to tell support what happened?")
      }
      .sheet(item: $sheet) { destination in
        switch destination {
        case .report(let item): ReporterView(reporter: reporter, incident: item, chatGPT: chatGPT)
        case .diagnostics(let text):
          NavigationStack {
            ScrollView { Text(text).textSelection(.enabled).padding() }
              .navigationTitle("View Diagnostics")
              .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { sheet = nil } }
              }
          }.frame(minWidth: 300, minHeight: 400)
        }
      }
  }
}
private enum Destination: Identifiable {
  case report(Incident)
  case diagnostics(String)
  var id: String {
    switch self {
    case .report(let i): i.incidentId
    case .diagnostics: "diagnostics"
    }
  }
}
extension View {
  public func startTestingIncidents(reporter: Reporter, chatGPT: ChatGPTAuth? = nil) -> some View {
    modifier(IncidentReporting(reporter: reporter, chatGPT: chatGPT))
  }
}
