import Foundation
import StoreKit

public enum BuildResolver {
  public static func resolve(
    environment: AppEnvironment = .auto, distribution: Distribution = .unknown,
    bundle: Bundle = .main
  ) -> BuildInfo {
    var selected = environment
    var source = distribution
    if source == .unknown,
      let raw = bundle.object(forInfoDictionaryKey: "StartTestingDistribution") as? String
    {
      source = Distribution(rawValue: raw) ?? .unknown
    }
    if selected == .auto,
      let raw = bundle.object(forInfoDictionaryKey: "StartTestingEnvironment") as? String
    {
      selected = AppEnvironment(rawValue: raw) ?? .unknown
    }
    if selected == .auto {
      switch source {
      case .testflight, .githubPrerelease, .msixFlight: selected = .beta
      case .appStore, .githubRelease, .microsoftStore: selected = .production
      case .xcode, .debug: selected = .development
      default: selected = .unknown
      }
    }
    #if os(iOS)
      let os = "iOS"
    #else
      let os = "macOS"
    #endif
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "x86_64"
    #endif
    return BuildInfo(
      environment: selected, distribution: source,
      version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "unknown",
      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      commit: bundle.object(forInfoDictionaryKey: "StartTestingCommit") as? String ?? "",
      os: os, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: architecture)
  }
  // Opt in: StoreKit may need network access. A sandbox transaction is only a beta
  // signal, not proof that this is TestFlight or that this user is a tester.
  public static func storeDistribution() async -> Distribution {
    do {
      guard case .verified(let transaction) = try await AppTransaction.shared else {
        return .unknown
      }
      switch transaction.environment {
      case .production: return .appStore
      case .sandbox: return .testflight
      case .xcode: return .xcode
      default: return receiptDistribution()
      }
    } catch { return receiptDistribution() }
  }
  /// The same binary ships to TestFlight and the App Store, so a build setting
  /// cannot tell them apart; the store receipt can.
  private static func receiptDistribution() -> Distribution {
    guard let name = Bundle.main.appStoreReceiptURL?.lastPathComponent else { return .unknown }
    return name == "sandboxReceipt" ? .testflight : .unknown
  }
  /// Build information for a store-distributed app, decided at run time: TestFlight
  /// is a beta build and the App Store is production. Anything else keeps what the
  /// bundle declares.
  public static func resolveFromStore(bundle: Bundle = .main) async -> BuildInfo {
    switch await storeDistribution() {
    case .testflight: resolve(environment: .beta, distribution: .testflight, bundle: bundle)
    case .appStore: resolve(environment: .production, distribution: .appStore, bundle: bundle)
    default: resolve(bundle: bundle)
    }
  }
}
