# CRTEngine's host contract → moved into the library

The canonical, generalized host contract now lives **in CRTEngine**, where every consumer
finds it:

> `CRTEngine/docs/HostContract.md`  (`~/Projects/Code/Swift/CRTEngine/docs/HostContract.md`)

It states what any host must do to drive the engine correctly — render intent, gamma-encoded
input, reporting signal/display facts vs the decisions the engine owns, presenting through
`DisplayCompositor`, matching the drawable's transfer, and the versioning guarantees that
make an upgrade safe.

## 86Box specifics

86Box is the reference **`.displayOnly`** host: it presents 1:1 to a physical panel via
`DisplayCompositor` and reports the true signal (resolution, refresh, interlace) and the
physical display. The bridge implementation is `crtbridge/Sources/CRTBridgeC/CRTBridge.swift`;
its known-open items are tracked in `BRIDGE_HONESTY_AUDIT.md`.

## History

This file was originally a mid-investigation snapshot (2026-07-14) taken while the 86Box
bridge was first being built against the engine. Most of what it flagged as divergent or
UNKNOWN has since been resolved — the composite is now the engine's `DisplayCompositor`, the
SDR transfer is handled, the phosphor buffer is panel-flexible, and the "load-bearing
scanline snap that is NOT UNDERSTOOD" turned out to be beam undersampling on the panel grid
(fixed in CRTEngine 1.2.x). The original text is preserved in this repo's git history if you
need the archaeology.
