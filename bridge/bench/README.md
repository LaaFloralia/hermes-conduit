# Drive player fixture measurements

These commands use a synthetic video, a throwaway paired Bridge, and a fake
Drive adapter. They do not access a Google account, a simulator, or user data.
`ffmpeg` with `libx264`, `swiftc`, and macOS AVFoundation are required.

```sh
node bridge/bench/drive-range-transfer-test.mjs
node bridge/bench/drive-player-macos.mjs 10 256 0 bytes
node bridge/bench/drive-player-macos.mjs 10 256 0 blocks
node bridge/bench/drive-player-macos.mjs 10 1024 0 blocks
node bridge/bench/drive-player-macos.mjs 10 256 2000 blocks
```

The player benchmark compiles the actual `LAADrivePlayer` class from the
current iOS source with a modeled Range transport and macOS AVFoundation. It
measures the first available decoded pixel buffer and the first decoded buffer
after a seek to four seconds. The generated six-second H.264/AAC fast-start MP4
is 2,953,344 bytes, with a roughly 4 Mbit/s video stream. Each network hop has
a simulated 50 ms RTT and 20 Mbit/s bandwidth, without loss. The iPhone-to-Mac
RTT is injected before each request; the equal-rate bandwidths are pipelined.
The temporary video, executable, and fake pairing state are removed afterward.
`bytes` models the existing byte-at-a-time client; `blocks` uses the new
bounded delegate. The cache option is an **idealized** fake that assumes the
version and permissions never change; it is not a production cache.

| Variant, 10 repetitions | First buffer p90 | Seek buffer p90 | Local requests before first buffer / after seek | Fake Drive metadata / media requests |
| --- | ---: | ---: | --- | --- |
| Existing 256 KiB, bytes | 3,031 ms | 2,319 ms | 3 / 2 each trial | 31 / 31 |
| 256 KiB, bounded blocks | 513 ms | 279 ms | 3 / 2 each trial | 31 / 31 |
| 1 MiB, bounded blocks | 809 ms | 1,212 ms | 3 / 1 each trial | 40 / 40 |
| 256 KiB, blocks, ideal 2 s metadata cache | 424 ms | 228 ms | 3 / 2 each trial | 10 / 31 |

With the existing transport, a completed 256 KiB body took approximately
899–2,671 ms after headers in this run, despite an emulated wire time of about
105 ms. The first two-byte probe and each later range also incurred separate
metadata and media RTTs. For this small fixture, simply increasing the chunk
to 1 MiB delayed both first and seek buffers and transferred about 29.5 MB over
ten trials, versus 5.2 MB for 256 KiB. The ideal cache saved roughly 89 ms at
startup and 51 ms at seek in this run, but assumes away version and permission
changes, so it is not an authorization-safe design.

These are Mac-side fixture measurements, not iPhone display timings or real
Drive results. The bounded transport is not yet wired into the shared iOS
transport file. Long videos, changing files, real-network behavior, PiP,
AirPlay, and the iOS integration remain to be tested separately.
