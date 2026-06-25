# Release process — Murmur Studio

The promotion path is **local build → TestFlight → public App Store**.
Every public release passes through TestFlight first so the build gets
exercised on a real machine before paying users see it.

## Before archiving

- [ ] Working tree is clean (`git status` shows no uncommitted changes)
      and on `main` at the commit you intend to ship.
- [ ] `git pull` so the local branch matches `origin/main`.
- [ ] Bump version numbers in the Murmur target (Signing & Capabilities
      → General):
  - `MARKETING_VERSION` — user-visible version (e.g. `1.0` → `1.0.1`).
        Bump for any user-facing release.
  - `CURRENT_PROJECT_VERSION` — build number. **Must increase for every
        upload** (Apple rejects duplicates). Increment by 1 each time.
- [ ] Tests are green: `Product → Test` (or run via the Murmur scheme).
      All suites must pass before archiving.
- [ ] Build is clean: `Product → Build`. No warnings about signing,
      entitlements, or missing assets.
- [ ] If the release adds or removes any entitlement, capability, or
      sandbox permission, double-check `Info.plist` keys + the Signing
      & Capabilities tab — Apple review will scrutinise.

## Archive + TestFlight upload

1. **Destination**: top of the Xcode window, change destination to
   **Any Mac (Apple Silicon, Intel)**. Not "My Mac" — that builds a
   debug binary, not an archive-ready release.
2. **Product → Archive**. Takes a few minutes; the **Organizer** window
   opens automatically when done.
3. In Organizer, confirm the archive shows the bumped version + build
   number and a `Murmur Studio` identity.
4. Click **Distribute App → App Store Connect → Upload**. Accept
   defaults (automatic signing, upload symbols).
5. Wait for the "Build uploaded" confirmation. Processing on Apple's
   side takes 10–30 minutes; you'll get an email when the build is
   ready in App Store Connect.

## Smoke test on TestFlight

Once the build is "Ready to Test" in App Store Connect → TestFlight,
install it on your machine via the TestFlight app and run the
checklist below before promoting. Catch regressions here, not in
public review.

### Launch
- [ ] App launches without errors or hangs.
- [ ] Window opens at the default size (1320×880) with everything
      visible — no content clipped behind the Dock, all strips
      reachable without scrolling.
- [ ] Resize the window down to ~1100×720 (the new minimum) and
      verify the layout still works — strips scroll into view, no
      content disappears off-screen.
- [ ] Window cannot be resized below ~1100×720.

### Welcome flow
- [ ] **"Try a sample recording"** loads the synthetic fixture and
      drops you into the bedside view with the synth annotations
      visible (3 findings: VT range + VF point + VT range).
- [ ] **"Open Record Folder"** invokes the file picker and accepts
      a folder selection. A folder with WFDB records loads cleanly.
- [ ] Recent-folder rows appear and reopen successfully.
- [ ] Drag-and-drop a folder onto the welcome view opens it.

### Bedside layout
- [ ] Lead chip bar shows every ECG lead; tapping a chip switches focus.
- [ ] Focus / Strips toggle behaves as expected.
- [ ] Trend rows (HR, SpO₂, etc.) render with the new layout — name
      and value left, vertical divider, sparkline right. No
      sparkline-over-label overlap.
- [ ] Alarm strip, state backdrop strip, and quality strip render
      when the recording has those signals.
- [ ] X-axis tick labels never overlap at any zoom level — try the
      default 10s window, zoom in, zoom out.

### Interaction
- [ ] Drag pans the canvas in lock-step across leads.
- [ ] Pinch zooms.
- [ ] Click on the overview ribbon scrubs the viewport.
- [ ] Findings list (right sidebar) populates and clicking a row
      jumps the viewport.
- [ ] Confirm / dismiss / reset on a finding requires the lock
      toolbar latch.
- [ ] Notes editor in the context panel respects the lock latch.

### Visual hygiene
- [ ] App icon shows in Finder, Dock, and the About window.
- [ ] Window title shows "Murmur Studio" (not "Murmur").
- [ ] No console errors during normal use (check Console.app
      filtered to the process).

## Promoting to public App Store

When the smoke test is clean:

1. In App Store Connect → **App Store** tab → **+ Version**.
2. Choose the version number that matches `MARKETING_VERSION`.
3. Attach the build from TestFlight.
4. Write release notes (what changed). Keep them user-facing — no
   internal jargon.
5. Verify the metadata didn't drift (description, keywords,
   screenshots if changed).
6. **Submit for Review**. Standard turnaround is 24–48h.

## Post-release

- [ ] Tag the release in git: `git tag v1.0.1 && git push --tags`.
- [ ] Bump the version in any docs that pin the latest released
      version.
- [ ] Watch for crash reports in App Store Connect → TestFlight →
      Crashes for the next few days.

