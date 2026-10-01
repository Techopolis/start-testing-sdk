# Environments and distributions

Canonical environments: development, beta, production, unknown, auto. Auto is a
configuration request; resolved BuildInfo contains an effective environment.
Distribution remains separate, with platform values declared in the shared models.

Strong signals: xcode/debug -> development; testflight/github_prerelease/msix_flight
-> beta; app_store/github_release/microsoft_store -> production. A plain MSIX,
PyInstaller bundle, virtual environment or source checkout does not identify the
environment by itself. Unknown defaults to restricted support behavior.

Python resolves explicit function arguments before environment variables, then
explicit build JSON, then distribution signals. For frozen auto-configured Python
apps, a bundled starttesting_build.json is discovered under PyInstaller's runtime
bundle directory. No GitHub lookup occurs at startup. The packaging script writes
metadata separately for beta and production artifacts.

.NET supports START_TESTING_ENVIRONMENT, START_TESTING_DISTRIBUTION,
START_TESTING_VERSION, START_TESTING_BUILD and START_TESTING_COMMIT, with optional
JSON metadata and explicit overrides. Package identity is not authorization.

Apple accepts explicit BuildInfo and Info.plist StartTestingEnvironment,
StartTestingDistribution and StartTestingCommit values. The opt-in StoreKit helper
uses a verified AppTransaction environment. A sandbox transaction is a beta signal,
not a definitive TestFlight origin test. StoreKit local testing and direct builds
need explicit metadata. There is no internal/external TestFlight privilege heuristic.
