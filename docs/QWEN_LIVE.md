# Qwen Live: direct audio on iPhone and Apple Watch

Qwen uses the shared **Gemini / Qwen Live** mode. Select the provider per
Hermes profile on the host; Gemini remains the default. This integration
keeps the existing `gemini-live` preference/history identifiers so that
launch paths, CarPlay and incoming calls reuse the direct-call controller.
Qwen is not a separate picker item.

## Setup

Install the modified notifier and app. In the profile's `.env`, set:

```dotenv
CONDUIT_DIRECT_LIVE_PROVIDER=qwen
DASHSCOPE_API_KEY=your-permanent-bailian-key
CONDUIT_QWEN_LIVE_WORKSPACE=your-workspace-id
CONDUIT_QWEN_LIVE_REGION=cn-beijing
CONDUIT_QWEN_LIVE_MODEL=qwen3.8-omni-flash-realtime
CONDUIT_QWEN_LIVE_VOICE=Tina
```

The workspace and key must match the region. Singapore is `ap-southeast-1`.
Restart the Hermes gateway, then select **Gemini / Qwen Live** on the phone
and Watch. Qwen's voice comes from the host setting above; the existing
Gemini voice picker only affects Google. Set the provider back to `gemini`
to return to Google. Failed Qwen requests never fall back to Google or
expose the permanent key.

Update both iPhone and Watch apps together. Watch voice protocol version 3
rejects older Watch clients before issuing credentials, since they do not
understand Qwen's direct connection and authentication.

## Paths and behavior

```text
Startup: phone -> Hermes /direct-live/token -> Alibaba temporary token API
         phone -> Watch: short-lived credential and call setup
Audio:   iPhone or Watch <-> Alibaba Realtime WebSocket
Tools:   device -> existing Hermes tools/jobs -> result -> Qwen
```

The host returns a 120-second temporary API key. The device authenticates
in the WebSocket header, never the URL. Reconnects mint new credentials.
Watch reconnect credentials and tool requests can still use the existing
encrypted relay grant when the phone is unreachable. **Audio never uses
that relay or the Hermes host.**

The direct-mode consent explicitly names Google / Alibaba Cloud. Previous
Google-only consent does not authorize this expanded mode. Phone-data
permissions remain shared with the existing direct mode.

The adapter uses 16 kHz mono PCM input and 24 kHz output, translates audio,
transcripts, VAD/interruption and function calls, and accepts text/job updates
for proactive speech. A reconnect starts a new Qwen session and asks the
controller to restore context; Google resumption handles are not forwarded.

Qwen native search cannot be combined with function tools. Search therefore
uses Hermes web search when configured, or Hermes jobs otherwise. The Google
Search preference does not activate Google Search on Qwen.

Incoming-call signaling still uses relay/APNs. After answering, the device
connects directly to Qwen through the existing direct-mode incoming-call path.

## Validation limits

Python tests mock upstream token responses; Swift tests use fake sockets.
Before deployment, verify temporary-key acceptance at the workspace
Realtime endpoint, token expiry during an established call, interruptions,
parallel tools, incoming-call openings and reconnection with real credentials.
Test Watch with the wrist down, on Wi-Fi/cellular and without the iPhone.
Windows cannot build iOS/watchOS targets: run XCTest in Xcode on macOS.

References: [Realtime](https://help.aliyun.com/zh/model-studio/realtime),
[events](https://help.aliyun.com/zh/model-studio/client-events),
[temporary keys](https://help.aliyun.com/zh/model-studio/generate-temporary-api-key).
