# Design handoffs

Versioned design material, one dated directory per handoff. These are
working documents — wireframes, specs, screenshots — kept in the repo so
the issues that implement them cite files that outlive anyone's Downloads
folder. The provenance chain runs: handoff directory → tracking issue →
region issues → PRs.

This directory is excluded from the published docs site (`_config.yml`
`exclude:`) — it is not product documentation.

| Handoff | Tracking issue | Canonical option |
| --- | --- | --- |
| [2026-08-15-main-window](2026-08-15-main-window/) — main window: toolbar, navigator, pinned stage, anchored notes, trend stack, info bar, review queue | [#252](https://github.com/kvnlng/Murmur/issues/252) | `11a` (launch `12a`, trend stack `13a`, notes `8a`/`9a`) |

Reading a handoff: start with its `README.md` (the spec), then open
`ECG Analyst Wireframes.dc.html` in a browser (keep `support.js` beside
it). Option ids badge each drawing; the spec's *Reading the design file*
table says which are canonical and which are history. Where a handoff and
the shipped code disagree on a fact, the code wins — the tracking issue
records the divergences found.
