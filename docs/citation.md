---
title: Citing Murmur Studio
---

# Citing Murmur Studio

If you use Murmur Studio in research, please cite it. The free viewer
is open-source under MIT and tracked by Zenodo for DOI-stable citation;
each paid extension carries its own citation surface so attribution
routes back to the right artifact.

The in-app **Copy citation** action (App menu, planned for the v1.1
release alongside Silver Layer Metrics) emits the appropriate
combination for the work currently loaded — researchers cite whatever
the tool hands them, so the routing below is enforced automatically.

## Routing by tier

| What was used | What to cite |
|---|---|
| **Free viewer only** (MurmurCore — file import, finding display, filter chips, viewport, disposition workflow) | Murmur Studio + the Zenodo release DOI |
| **Annotation Authoring IAP** (manual finding create / edit / delete) | Murmur Studio + Zenodo release DOI. No method paper — the IAP wraps editing UX, not a published algorithm. |
| **Silver Layer Metrics IAP** (cardiopulmonary telemetry feature extraction) | Murmur Studio + Zenodo release DOI **plus** the modular-feature method paper (citation TBD until publication). |
| **VT/VF Detection IAP** (SE-ResLSTM inference) | SE-ResLSTM paper (citation TBD until publication) **plus** Murmur Studio + the specific VT model version DOI. Model version is encoded in each finding's metadata so screenshots in your paper self-document provenance. |

## BibTeX (free viewer)

> *DOI and version below are placeholders; the canonical entry will be
> populated by Zenodo's GitHub-release integration once the first
> tagged release ships.*

```bibtex
@software{murmur_studio,
  author       = {Long, Kevin},
  title        = {{Murmur Studio: A native macOS viewer for
                   PhysioNet WFDB recordings}},
  year         = {2026},
  publisher    = {Zenodo},
  version      = {1.0.0},
  doi          = {10.5281/zenodo.XXXXXXX},
  url          = {https://github.com/kvnlng/Murmur}
}
```

## RIS (free viewer)

```
TY  - COMP
AU  - Long, Kevin
TI  - Murmur Studio: A native macOS viewer for PhysioNet WFDB recordings
PY  - 2026
PB  - Zenodo
ET  - 1.0.0
DO  - 10.5281/zenodo.XXXXXXX
UR  - https://github.com/kvnlng/Murmur
ER  -
```

## VT model versioning (reproducibility)

The VT Detection IAP runs an on-device Core ML model that is
continuously improved between app releases via signed manifest
updates. **Every published model version stays DOI-addressable
forever** — we never overwrite or delete a published version.

If you cite a finding produced by the VT model, the Copy citation
action includes the exact model version DOI alongside the Murmur
Studio release DOI. To pin your analysis to a specific model version
during a paper-in-progress, toggle **Freeze model version** in the
Settings window; the app will refuse silent upgrades until you
release the toggle.

This is the structural advantage of an on-device, versioned-manifest
model over cloud-inference services — your analysis is reproducible
years after publication, even if the latest model version has moved
on.

## Acknowledging the open ecosystem

Murmur Studio reads the [PhysioNet WFDB
format](https://www.physionet.org/physiotools/wpg/) and aims to be
continuous with the broader PhysioNet software ecosystem (Vest 2018
CV Signal Toolbox, ECG-Kit, etc.). If your work also depends on
those tools, please cite them according to their authors' guidance —
Murmur is a viewer + analyst surface, not a replacement for any of
the algorithmic work upstream.
