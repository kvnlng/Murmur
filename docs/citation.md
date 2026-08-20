---
title: Citing Murmur Studio
---

# Citing Murmur Studio

If you use Murmur Studio in research, please cite it. The viewer is
open-source under MIT and tracked by Zenodo for DOI-stable citation.

The in-app **Copy Citation** actions (Help menu — BibTeX or RIS) emit
the entry for the running version and write it to the clipboard, so the
version you cite is the version you ran.

## What to cite

| What was used | What to cite |
|---|---|
| **The free viewer** (import, calibrated paper, annotation layers, review dispositions, exports) | Murmur Studio + the Zenodo release DOI. |
| **Murmur Pro instruments** (beat calipers and interval trends, HRV / QT-variability metrics, the arrhythmia scan, morphology clustering, annotation authoring) | The same Murmur Studio entry + release DOI. The measures are community-standard (HRV statistics, interval measurement, QTc correction formulas named in-app); no separate method paper exists for the instrument implementations. |
| **Arrhythmia scan findings** (VT/VF candidate episodes, rhythm-event candidates) | Murmur Studio + release DOI, **plus** the operating-point provenance the app displays with every candidate group — model, score threshold, and ranking basis are echoed in the queue header and in exported reports, so a screenshot or export self-documents how the candidates were produced. |

## Provenance in the app

Every computed surface states its own methods where you read it: which
lead was measured, which window and formula, what was excluded and why.
Lane headers and queue captions echo the exact configuration they ran
with, and exports carry the same statements — the figure you publish
names its provenance without a trip back to the app.

## BibTeX

The `doi` below is the **concept DOI** — it always resolves to the
latest archived version. If you need to pin to a specific release for
reproducibility, swap in the per-version DOI from the Zenodo record's
"Versions" panel (or use the in-app Copy Citation action, which emits
the running version).

```bibtex
@software{murmur_studio,
  author       = {Long, Kevin},
  title        = {{Murmur Studio: A native macOS viewer for
                   PhysioNet WFDB recordings}},
  year         = {2026},
  publisher    = {Zenodo},
  version      = {1.3.0},
  doi          = {10.5281/zenodo.21077528},
  url          = {https://github.com/kvnlng/Murmur}
}
```

## RIS

```
TY  - COMP
AU  - Long, Kevin
TI  - Murmur Studio: A native macOS viewer for PhysioNet WFDB recordings
PY  - 2026
PB  - Zenodo
ET  - 1.3.0
DO  - 10.5281/zenodo.21077528
UR  - https://github.com/kvnlng/Murmur
ER  -
```

## Acknowledging the open ecosystem

Murmur Studio reads the [PhysioNet WFDB
format](https://www.physionet.org/physiotools/wpg/) and aims to be
continuous with the broader PhysioNet software ecosystem (Vest 2018
CV Signal Toolbox, ECG-Kit, etc.). If your work also depends on
those tools, please cite them according to their authors' guidance —
Murmur is a viewer + analyst surface, not a replacement for any of
the algorithmic work upstream.
