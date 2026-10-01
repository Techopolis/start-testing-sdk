import StartTestingAuth
import StartTestingChatGPT
import StartTestingCore
import StartTestingUI
import SwiftUI

@main
struct StartTestingSampleApp: App {
  let services = MockServices()
  let client: StartTestingClient
  let reporter: Reporter
  let chatGPT: ChatGPTAuth?
  init() {
    chatGPT = try? ChatGPTAuth.standard(
      appName: "Start Testing SDK Sample", keychainService: "net.starttesting.sdk.sample.ChatGPT")
    client = StartTestingClient(
      projectId: "proj_demo", build: BuildInfo(environment: .beta, distribution: .githubPrerelease),
      options: Options(fullLogs: true), projects: services, authorization: services)
    reporter = Reporter(client: client, issues: services, feedback: services, attachments: services)
  }
  var body: some Scene {
    WindowGroup {
      SampleView(client: client, reporter: reporter, services: services, chatGPT: chatGPT)
    }
  }
}
struct SampleView: View {
  let client: StartTestingClient
  let reporter: Reporter
  let services: MockServices
  let chatGPT: ChatGPTAuth?
  @State private var status = "Local mock backend. No data is sent to Start Testing."
  @State private var manual: Incident?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Start Testing SDK sample").font(.title)
      Text(status)
      Button("Sign in as Mock Tester") {
        Task {
          do {
            try await client.setAuthorization(services.authenticate(projectId: "proj_demo"))
            status = "Mock tester authenticated. Full logs enabled."
          } catch { status = "Mock sign-in failed." }
        }
      }
      Button("Sign out") {
        Task {
          await client.signOut()
          try? await client.revalidate()
          status = "Anonymous beta feedback mode."
        }
      }
      Button("Perform test actions") {
        Task {
          await client.breadcrumb("Opened Preferences")
          await client.record("Preparing audio engine", type: .debug)
          status = "Actions recorded."
        }
      }
      Button("Trigger reportable error") {
        Task {
          await client.record(
            NSError(domain: "Sample", code: -10875), severity: .reportable,
            userMessage: "Unable to preview voice")
        }
      }
      Button("Open reporter") { Task { manual = await client.manualIncident() } }
    }
    .padding(24)
    .frame(minWidth: 320, minHeight: 340)
    .startTestingIncidents(reporter: reporter, chatGPT: chatGPT)
    .sheet(item: $manual) { incident in ReporterView(reporter: reporter, incident: incident, chatGPT: chatGPT)
    }
    .task { try? await client.revalidate() }
  }
}
