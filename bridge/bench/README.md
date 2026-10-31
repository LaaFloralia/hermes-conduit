# Drive player fixture measurements

These commands use a synthetic video, a throwaway paired Bridge, and a fake
Drive adapter. They do not access a Google account, a simulator, or user data.
`ffmpeg` with `libx264`, `swiftc`, and macOS AVFoundation are required.

```sh
node bridge/bench/drive-player-macos.mjs 10 256 0 bytes 50 20
node bridge/bench/drive-player-macos.mjs 10 256 0 bytes 150 10
node bridge/bench/drive-player-macos.mjs 10 1024 0 bytes 150 10
node bridge/bench/drive-player-macos.mjs 10 256 2000 bytes 150 10
```

The experimental block transport and its comparison harness are preserved in
commit `6dd10343`. They were removed from the app and current fixture because
the requested improvement threshold was not met.

The benchmark compiles the actual `LAADrivePlayer` class from the current iOS
source with a modeled Range transport and macOS AVFoundation. It measures the
first available decoded pixel buffer and the first decoded buffer after a seek
to four seconds. The generated six-second H.264/AAC fast-start MP4 is 2,953,344
bytes, with a roughly 4 Mbit/s video stream. The last two arguments model the
RTT and bandwidth **for each hop**. Equal-rate media hops are pipelined and
throttled approximately once; packets, loss, and variable conditions are not
modeled. The temporary video, executable, and fake pairing state are removed
afterward. Each variant below has ten trials; p90 is the ninth sorted value,
so the largest trial, including a cold first trial, is not the p90.

**Correction:** The previous benchmark executed the modeled byte-by-byte
transport on MainActor, unlike the existing iOS nonisolated async Bridge
client. Its 3,031/2,319 ms p90 and the claim that byte processing was the main
cause are invalid. In these reruns both modeled transports execute from a
nonisolated async function, under Swift 5 language mode.

| Per-hop RTT / rate | Variant | First buffer p90 | Seek p90 | Local calls before first buffer / after seek | Fake Drive metadata / media calls | Fake Drive bytes |
| --- | --- | ---: | ---: | --- | --- | ---: |
| 50 ms / 20 Mbit/s | 256 KiB, existing bytes | 534 ms | 309 ms | 3 / 2 in nine trials; 6 / 5 once | 36 / 36 | 6,279,316 |
| 50 ms / 20 Mbit/s | 256 KiB, experimental blocks | 476 ms | 302 ms | 3 / 2 in nine trials; 6 / 5 once | 35 / 35 | 6,279,316 |
| 150 ms / 10 Mbit/s | 256 KiB, existing bytes | 1,204 ms | 689 ms | 3 / 2 each trial | 31 / 31 | 5,242,900 |
| 150 ms / 10 Mbit/s | 256 KiB, experimental blocks | 1,375 ms | 749 ms | 3 / 2 each trial | 32 / 32 | 5,242,900 |
| 150 ms / 10 Mbit/s | 1 MiB, existing bytes | 2,483 ms | 2,552 ms | 3 / 1 each trial | 40 / 40 | 29,533,460 |
| 150 ms / 10 Mbit/s | 256 KiB, ideal 2 s metadata cache | 1,022 ms | 2,296 ms | 3 / 6 each trial | 20 / 71 | 12,985,620 |

Local call counts include requests subsequently canceled before reaching the
fake Drive. Player request scheduling varied between runs: in the ideal-cache
case it read additional ranges around the seek, so these results do not prove
that a cache itself increases seek latency. That cache assumes the version and
permissions never change and is not a safe production design. On this small
fixture, neither larger chunks nor the experimental block transport showed a
clear 30% improvement in startup or seek; keep the existing 256 KiB transport.
The experimental transport was never wired into the iOS client.

These are Mac-side fixture measurements, not iPhone display timings or real
Drive results. They do not establish behavior for long videos, other codecs,
changing files, loss, variable bandwidth, PiP, or AirPlay.
