# QA — Help & FAQ screen (PR #45) — 2026-06-06

**Verdict: PASS** (orchestrator-verified; the building agent was interrupted mid-smoke).

- Diff scope: `FAQHelpView.swift` (new), `SettingsView.swift` (top "Help" section → NavigationLink), `FAQHelpViewTests.swift` (new). No map/overlay/gesture/service files — low #31 risk.
- The 3 NYC.gov links match the official URLs exactly (ASP calendar page, 2026 PDF, parking rules). Content per `docs/in-app-faq-content.md`.
- Build + full test suite: `** TEST SUCCEEDED **`, 0 failures, RegionSyncGuardTests pass.
- Visual smoke (tap Settings → Help & FAQ) deferred to Kevin's hands-on on the merged build — the static screen can't be tab-navigated via simctl.
