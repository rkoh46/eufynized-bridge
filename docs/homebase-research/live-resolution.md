# Why live view starts at 720p

S3 Pro cameras on the HomeBase 3 start every live stream small and step up: 720p → 1080p → 2K (2304x1296) →
4K (3840x2160). The Streaming Quality setting is already Max (1705 value 10), and the cameras still ramp.

## Experiment (2026-10-22)

`GET /api/experiment/ramp?ch=<n>&pre=0|1&streamtype=<n>&seconds=45` on the bridge opens its own session and records
when each new resolution arrives. Front door is ch2 and Driveway is ch1. Each run waited 20 s after the last one.

| Mode | Front door 4K | Driveway 4K |
|---|---|---|
| Today: Max sent after the start, `streamtype` 1 | 29.9 s, 30.9 s | 8.4 s, 9.5 s |
| Max sent before the start | 25.8 s, 32.0 s | 10.3 s, 9.2 s |
| `streamtype` 0 | 31.1 s | 8.7 s |
| `streamtype` 2 | never in 45 s (bounced 720p ↔ 1080p) | 8.9 s |
| `streamtype` 3 | 36.8 s | 8.0 s |

The official app's 1003 start payload carries the same keys Eufynized sends (`streamtype`, `ClientOS`,
`entrytype`; strings in `BC_P2PClient`). `startRTVideoStream:modStr:` passes a mode string into native code and
holds no resolution field.

## Conclusion

Neither the start command nor the quality setting changes the ramp. The camera raises its resolution as it
measures its Wi-Fi link, so a weaker link means a slower ramp: Front door is about 30 s, Driveway about 9 s.
Eufynized keeps `streamtype` 1 with Max after the start. The `qualityBeforeStart` and `streamType` options on
`EufyLiveStream.Config` stay for future probing.

A full-resolution alert picture therefore has to wait for the stream to get there (a follow-up picture), or come
from the event recording.
