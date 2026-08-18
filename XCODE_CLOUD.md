# Xcode Cloud setup — Murmur Studio

Walkthrough for setting up automated test + archive runs on Apple's
hosted CI for this project. Quality Infrastructure Phase 2 of the
plan captured in `ROADMAP.md`.

Xcode Cloud is free for paid Apple Developer Program members up to a
generous compute-hour cap. For this project the day-to-day load is
small — every run is started by hand, so nothing accumulates on its
own — and we're nowhere near the cap.

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

## The workflows, as they are actually configured

Read from the API rather than from memory — an earlier version of this
file described two workflows by names that do not exist, with start
conditions that had been removed. Re-read it the same way before
trusting it:

```
scripts/xcode-cloud.rb get /v1/ciProducts/<product-id>/workflows
```

**`Default`** — enabled. Actions: **Test — macOS** (scheme `Murmur`,
which picks up both unit and UI suites via the `Murmur` test plan) and
**Archive — macOS** (`ANY_MAC`). This is the one to start for a normal
verification run; it both tests and archives.

**`Release Build`** — enabled. Actions: **Archive** only.

**Both are manual-start.** Neither carries a branch, tag, pull-request,
or scheduled start condition — `manualBranchStartCondition` matching all
branches is the only condition on either. Nothing in this repository
triggers a build by being pushed, tagged, or merged.

That is a deliberate choice: a run should happen when the work is ready
to be judged. It does mean nothing is watching, so a regression sits
undiscovered until someone starts a build.

### If you are setting this up from scratch

In App Store Connect the workflow editor covers environment (Xcode and
macOS both **Latest Release**), actions, and post-actions — email
notification to `long.kevin@gmail.com` is set on completion.

One constraint worth knowing before adding an OS matrix: the deployment
target is `MACOSX_DEPLOYMENT_TARGET = 26.5` in the pbxproj, so older
macOS versions will not install the build at all. Confirm the target in
the Murmur target's Build Settings before adding older destinations.

## What's automatic from here

Nothing. That is the whole answer, and this section used to say the
opposite in both directions.

Neither workflow has an automatic start condition. Pushing to `main`
starts nothing; tagging `v1.1` starts nothing; opening a pull request
starts nothing. A build happens when a person asks for one, via
`scripts/xcode-cloud.rb start <branch>` or App Store Connect. A test run
takes ~5–10 minutes per OS-version.

Because runs are manual, a branch's tests are only exercised on the
runner when someone asks — and Xcode Cloud does not run on pull
requests either, so a branch nobody starts has never been near the
runner at all.

Merging first and running once on `main` is the normal flow, and the
cheaper one: a single run judges the accumulated work instead of
spending quota per branch. Build a branch directly when you want to
isolate it — a change you suspect, or one you would rather not have
`main` red for while you find out.

## Updating the release process

Applied — `RELEASE.md`'s "Archive + TestFlight upload" section now
carries this flow (tag for provenance, then start `Release Build` by
hand) and is the single place the release steps live. Before the
update, that section claimed the tag push itself made Xcode Cloud
test, archive, and ship — a start condition neither workflow has
ever had. If the two files disagree again, this one is checked
against the actual workflow configs; trust it.

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

## The Cloud runner's screen is shorter than yours

This is the single most useful thing to know before debugging a UI test
that fails only on Cloud.

The hosted runner records at 2560×1600, and the app window ends up
materially shorter there than on a developer Mac. The bedside trace
panel does not shrink to fit — it keeps its height and is **clipped at
the panel's bottom edge**, while the accessibility frame of the element
inside it stays full height.

That combination breaks a specific and very common test idiom:

```swift
let centre = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
centre.hover()
```

XCUI computes that point from the element's *reported* frame, not from
the part you can see. When the frame is taller than the visible region,
`dy: 0.5` resolves to a point **below the drawn trace** — in the
observed failures, onto the status-bar row. The hover lands on nothing,
no beat is focused, and every subsequent click or right-click at that
coordinate acts on empty space.

The tell is the docked beat card: it sits on `Hover the trace to focus
a beat` (or `No beats in this record`) for the whole run, while the test
believes it is hovering a beat. Because `docked-beat-inspector` always
exists since #246, `card.exists` does not catch this — it is true
either way, so a test can pass its own setup assertions vacuously and
only fail later on the assertion that actually matters.

**When writing a UI test that must land on the trace, do not trust a
normalized offset.** Anchor to a beat's own element, or assert that a
beat is genuinely focused (a beat-specific identifier, not the card
container) before relying on the position.

## Why the test plan retries

`Murmur.xctestplan` sets `testRepetitionMode: retryOnFailure` with
`maximumTestRepetitions: 3`. The plan is JSON and cannot carry a
comment, so the reasoning lives here.

**Read the history before trusting this setting.** It was added on a
diagnosis that turned out to be wrong. Build 138 failed on
`testAPinnedBeatCardSurvivesThePointerLeavingTheTrace` and
`testAbstentionNullStateAndManualCaliperOverride`; both passed 3/3
locally, so they were called flakes and retries were added to stop one
flake failing a build. Build 140 then ran both **3 times each under the
retry policy and failed all 3** — they are deterministic on the runner,
for the screen-geometry reason above, and were never flakes. Passing
locally does not make a failure intermittent.

The setting is kept because it costs nothing: retries only fire on
failure, so the green path is unaffected, and a genuinely intermittent
failure is worth absorbing. It is **not** load-bearing for the two
failures above and does not fix them.

**The cost, stated plainly:** a real regression that fails
intermittently will now be retried into a pass and go unnoticed. If a
test starts needing its retries to go green, that is a signal to
investigate, not to raise the repetition count.
`scripts/xcode-cloud.rb` is how you check whether a passing build
needed retries to get there — the `.xcresult` reports `Test case with
N runs` per test.

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

**Failing UI tests record video, and it is usually the fastest answer.**
`xcrun xcresulttool export attachments --test-id <id> --path <bundle>
--output-path <dir>` writes one `.mp4` per attempt plus the query debug
descriptions. Reading a few frames beats reasoning about the
accessibility tree — the screen-geometry problem above was invisible in
the logs and obvious in the first frame. Note that
`AVAssetImageGenerator` refuses an exact-time fetch at `t=0` on these
recordings (`AVFoundationErrorDomain -11832`); request a keyframe
tolerance of about a second and start slightly after zero.

Compare the failing run's activity list against a local passing run
(`xcrun xcresulttool get test-results activities --test-id …`) before
theorising. If the two sequences are identical — same elements, same
coordinates — then XCUI did the same thing both times and the
difference is in how the app responded, which rules out a whole class
of guesses about lost or mistimed events.

One trap: a `crash_log_bundle_*` artifact does **not** imply the app
crashed. `MetricMeasurementHelper` is Apple's own XCTest
performance-metrics helper and aborts routinely on the hosted runners;
check the `.ips` `bundleID` before reading anything into it.

## Starting a run

```
scripts/xcode-cloud.rb start <branch> [workflow-name]
```

Defaults to the `Default` workflow. The branch must already be pushed —
Xcode Cloud builds a git reference it knows about, not your working
tree — and the command refuses an unknown branch or workflow rather
than starting the wrong thing.

This is the only subcommand that spends compute against the monthly
quota, which is why it is explicit and why nothing else does it as a
side effect. Watch it with `scripts/xcode-cloud.rb run latest`.

Usually you want `main`, after merging: one run judges everything that
landed. Naming a branch is for when you want a change isolated from the
rest — which is what the argument is there for, not a standing
instruction to build every branch.

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
