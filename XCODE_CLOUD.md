# Xcode Cloud setup — Murmur Studio

Walkthrough for setting up automated test + archive runs on Apple's
hosted CI for this project. Quality Infrastructure Phase 2 of the
plan captured in `ROADMAP.md`.

Xcode Cloud is free for paid Apple Developer Program members up to a
generous compute-hour cap. For this project the day-to-day load is
small — tests run on push, archives run on tags — and we're nowhere
near the cap.

## Prerequisites

Already in place:
- Apple Developer Program enrollment (you enrolled before the v1.0
  submission)
- App Store Connect record for Murmur Studio (App ID `6782092325`)
- Repo at `github.com/kvnlng/Murmur` with `main` as the trunk
- Tests green locally: 191 unit + 7 UI = 198 total at the time of
  writing

You don't need any local CLI or Apple-side credential setup to *create*
the workflows — that happens in App Store Connect's web UI, and Apple
manages all signing certificates and provisioning profiles
automatically. Reading build results from the terminal afterwards does
need an API key; see "Reading results from the terminal" below.

## Initial workflow

1. **App Store Connect** → My Apps → **Murmur Studio**
2. Top tabs → **Xcode Cloud**
3. **Get Started** (first time) or **Manage Workflows** (subsequent)
4. **Connect repository** → GitHub → grant Apple's GitHub App access
   to `kvnlng/Murmur`. Apple only needs read access plus webhook
   installation. (This step predates the repo going public and used to
   note the private-repo OAuth scope; the grant is the same either way.)
5. After the repo connects, Xcode Cloud creates a default workflow.
   Edit it.

## Workflow: test on every push to main

**Name:** `Test on main`

**Start conditions:**
- Branch: **main**
- Start: **Branch changes**
- Files and folders changed: (leave empty — run on every push)

**Environment:**
- Xcode: **Latest Release**
- macOS: **Latest Release** (the test action's matrix below will
  also add older versions)

**Actions:**

1. **Test** action
   - Scheme: `Murmur`
   - Destination: configure the matrix:
     - **macOS, Latest Release** (Tahoe 26 / current)
     - **macOS, Sequoia 15.x** (if available — gives one-version-back coverage)
     - Skip **Sonoma 14.x** unless we lower the deployment target
       (currently `MACOSX_DEPLOYMENT_TARGET = 26.5` in pbxproj, so
       older OSes won't even install the build — confirm in the
       Murmur target's Build Settings before adding older
       destinations)
   - Test plan: the default `Murmur` plan picks up both unit and UI
     suites

**Post-actions:**
- **Notify** → Email on success and failure to `long.kevin@gmail.com`

**Save.**

## Workflow: archive + TestFlight on git tag

**Name:** `Archive on tag`

**Start conditions:**
- Tag: **Any Tag** matching `v*` (we tag releases as `v1.1`, `v1.2`,
  etc. per RELEASE.md)
- Start: **Tag changes**

**Environment:** Latest Release / Latest Release.

**Actions:**

1. **Test** — same as the push workflow, but only on the latest macOS
   (don't burn matrix runs on releases)
2. **Archive** action
   - Scheme: `Murmur`
   - Distribution: **App Store Connect**
   - Deployment preparation: **TestFlight Internal Testing**

**Post-actions:**
- **TestFlight Internal Testing** — distributes to the internal
  tester group you set up earlier
- **Notify** → Email on completion

**Save.**

## What's automatic from here

Once both workflows are saved:

- Every push to `main` triggers the test workflow. You'll get an
  email on first failure (success emails are suppressed by default
  unless you opt in). Test runs ~5–10 minutes per OS-version.
- Every `v*` tag triggers an archive that lands in TestFlight
  automatically. The smoke-test checklist in `RELEASE.md` still
  applies — Xcode Cloud just removes the manual upload step.

## Updating the release process

After Xcode Cloud is wired up, the "Archive + TestFlight upload"
section in `RELEASE.md` simplifies to:

1. Bump version numbers (still manual)
2. `git tag v1.1 && git push --tags`
3. Wait for the Xcode Cloud archive email (~10–15 min)
4. Smoke-test the build in the TestFlight app
5. Promote in App Store Connect when ready

No more Product → Archive → Organizer → Distribute clicks.

## Cost / quota notes

- The paid Developer Program tier (which is what we have) includes 25
  compute hours per month
- A typical Murmur test run takes ~5 minutes; an archive takes ~10
- Expected usage: maybe 2 hours/month at our current cadence. Well
  under the cap.
- If we ever cross the cap, the matrix testing is the first thing to
  trim — drop older OS versions and run only Latest Release

## Custom build steps

One script in place:

- **`ci_scripts/ci_post_clone.sh`** — `brew install swiftlint`. The
  Murmur target has a "Run SwiftLint" Run Script Build Phase that
  shells out to the installed binary. We don't use the SwiftLint SPM
  build-tool plugin because (a) it forces a swift-syntax pin that
  blocks other SPM deps like `swift-snapshot-testing`, and (b) Xcode
  Cloud refuses to run SPM plugins without an explicit trust grant
  that has no UI on hosted runners. Brew sidesteps both.

Additional script hooks (currently unused): `ci_pre_xcodebuild.sh` /
`ci_post_xcodebuild.sh` in the same directory if we ever need them.

`Package.resolved` MUST stay tracked in git — Xcode Cloud disables
automatic SPM resolution, so a missing resolved file fails the build
with "a resolved file is required". The `.gitignore` has an explicit
note about this.

## Why the test plan retries

`Murmur.xctestplan` sets `testRepetitionMode: retryOnFailure` with
`maximumTestRepetitions: 3`. The plan is JSON and cannot carry a
comment, so the reasoning lives here.

The hosted runner is an `Apple Virtual Machine`, and UI tests time
differently there than on real hardware. Across seven consecutive Cloud
failures the pattern was always the same: one or two UI tests fail, a
*different* pair each time, and every one of them passes locally on
repeat runs. Build 138's two failures
(`testAPinnedBeatCardSurvivesThePointerLeavingTheTrace`,
`testAbstentionNullStateAndManualCaliperOverride`) each passed 3/3
locally and had never failed on Cloud before. With no retry policy, a
single such flake failed the whole build and burned a re-run of the
quota.

Retries only fire on failure, so the green path costs nothing.

**The cost, stated plainly:** a real regression that fails
intermittently will now be retried into a pass and go unnoticed. That
is a deliberate trade — made because the observed failures were all
flakes and none were real. If a test starts needing its retries to go
green, that is a signal to investigate, not to raise the repetition
count. `scripts/xcode-cloud.rb` is how you check whether a passing
build needed retries to get there.

## Reading results from the terminal

The failure email and the GitHub check-run summary give you the
assertion message and nothing else. The console log, the `.xcresult`,
and any crash logs live behind the App Store Connect API.
`scripts/xcode-cloud.rb` reads them. It needs system Ruby and nothing
else — no gems, no Homebrew.

**One-time key setup.** In App Store Connect → Users and Access →
Integrations → App Store Connect API → **Team Keys**, create a key with
the **Developer** role (verified sufficient for every Xcode Cloud read
endpoint; you do not need App Manager). Copy the **Issuer ID** from the
top of that page, then download the `.p8` — Apple allows that download
exactly once, and a lost key must be revoked and reissued rather than
recovered.

```
mkdir -p ~/.appstoreconnect/private_keys
chmod 700 ~/.appstoreconnect ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/private_keys/
chmod 600 ~/.appstoreconnect/private_keys/*.p8
printf '%s\n' '<ISSUER-ID>' > ~/.appstoreconnect/issuer_id
chmod 600 ~/.appstoreconnect/issuer_id
```

The key never enters this repo — the script reads it from the home
directory at runtime, and `.gitignore` carries `*.p8` / `AuthKey_*` so
a stray copy can't be committed by a wildcard `git add`. This matters
more than usual: the repo is public.

**Triaging a failure.** Start from the newest run and walk down:

```
scripts/xcode-cloud.rb run latest              # actions + their ids
scripts/xcode-cloud.rb artifacts <action-id>   # what's downloadable
scripts/xcode-cloud.rb download <artifact-id> /tmp/build
```

The `RESULT_BUNDLE` artifact is the one worth the download — unzip it
and `xcrun xcresulttool get test-results summary --path <bundle>` gives
pass/fail counts, then `... test-details --test-id <id>` gives the
per-test failure with attachments. `LOG_BUNDLE` is the raw build log.
Skip `TEST_PRODUCTS` unless you intend to re-run the suite locally; it
is ~126 MB of built binaries.

One trap: a `crash_log_bundle_*` artifact does **not** imply the app
crashed. `MetricMeasurementHelper` is Apple's own XCTest
performance-metrics helper and aborts routinely on the hosted runners;
check the `.ips` `bundleID` before reading anything into it.

## When something fails

- **Build failure:** Xcode Cloud shows the same build log Xcode does.
  Most failures are SwiftLint or Swift compile errors that would have
  caught us locally — fix locally, push, the next run goes green.
- **Test failure:** Open the workflow run in App Store Connect →
  view the failure → click into the failing test to see assertions
  and the device log. UI test failures sometimes need a re-run
  (flakiness from layout timing); persistent failures are real
  regressions.
- **Signing failure:** Xcode Cloud manages signing automatically, so
  these are usually wrong team selected or expired certificates.
  Check `DEVELOPMENT_TEAM = 7G75BYLCSE` in `project.pbxproj`.
