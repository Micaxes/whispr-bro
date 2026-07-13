# iOS distribution runbook

How whispr-bro-iOS reaches friends' phones (issue #13 review, adopted). One
channel decision up front: **TestFlight external private group is the friends
channel.** Everything else is either plumbing (internal) or rejected.

## Channels

| Channel | Who | Why / why not |
|---|---|---|
| TestFlight **internal** | Maintainer + 1–2 trusted smoke testers | Internal testers must be **App Store Connect team users** — team access is the wrong trust model for friends. No Beta App Review; builds appear as soon as processing finishes. Use it as the smoke-test gate only. |
| TestFlight **external, private group** | Friends | **The distribution channel.** Email invites, no ASC access, up to 10k testers. Requires **Beta App Review on the first build of each version** — and do not assume exactly one review per version; Apple can re-review later builds too. Budget review lag into every release. |
| TestFlight public link | Nobody, normally | Pressure valve only (e.g. an invite email keeps bouncing). A leaked link lets anyone install. |
| Ad-hoc / AltStore | — | **Rejected.** UDID collection per device, 100-device cap, re-signing friction — worse than TestFlight on every axis for this group. |

## Ops rules

1. **Bump `CFBundleVersion` on every upload.** Re-uploading an identical
   build number does NOT reset TestFlight's 90-day expiry.
   `scripts/make-ios-app.sh release` stamps it automatically:
   `<git commit count>.<UTC yyyymmddHHMMSS>` — the first segment is monotonic
   across commits, the timestamp breaks ties when the same commit is archived
   twice, no local state needed. Stamped into the archived plists via
   PlistBuddy (app + keyboard appex must match), never the checked-in ones.
   Constraint: don't archive an older commit after a newer one uploaded under
   the same marketing version — ASC requires build numbers to increase.
2. **Expiry clock runs from upload, not approval.** Alert at **30 / 14 / 7
   days** before a live build expires (calendar reminders until the CI
   `testflight-upload` job is enabled — see `.github/workflows/ci.yml`).
3. **Keep two approved builds overlapping.** Never let the only approved
   external build go into its final month without a successor already through
   Beta App Review.
4. **Smoke-test internal first, then promote.** Same build: internal group →
   dictate in the keyboard on a real device → add it to the external group.

## Per-release checklist

- [ ] `scripts/fetch-models.sh` run on the build machine (release bundles
      Parakeet v2 + Silero VAD; a model-less archive is a broken build)
- [ ] `WHISPR_DEV_TEAM` / `WHISPR_ASC_KEY_PATH` / `WHISPR_ASC_KEY_ID` /
      `WHISPR_ASC_ISSUER_ID` exported
- [ ] `scripts/make-ios-app.sh release` — note the stamped `CFBundleVersion`
- [ ] Build finishes ASC processing; smoke-test via the **internal** group
- [ ] Promote the same build to the **external** private group (first build
      of a new version: expect Beta App Review before friends see it)
- [ ] Previous approved build still has ≥ 30 days left; expiry alerts set
