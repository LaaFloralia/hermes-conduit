# Bridge: initial bootstrap failed after an approved bootout

On 2026-11-03, the owner approved one stop/start of `com.laa.bridge` on the Mac mini to enable the installed local voice worker. The implementation was master `8ef6cddc`; LAA Voice was `2.0.0 (2026110303)`. Hermes and Paseo were outside the stop scope.

The Bridge initially had PID 7550, returned HTTP 200 from its health endpoint, and held 16 existing device records. The operator added only `LAA_VOICE_WORKER` to the LaunchAgent environment and verified that the other settings were preserved. The approved `bootout` returned 0; the first `bootstrap` returned 5. Read-only diagnosis found the service unregistered, no listener on port 9137, and a valid plist. The launchd log recorded completion of the old service removal at 12:25:40 JST. Incomplete removal at the first bootstrap is consistent with these observations, but the cause is not proven.

No additional bootout occurred. A bootstrap-only retry completed the already approved start and returned 0. The recovered Bridge had PID 60984 and returned HTTP 200. The verification parent independently read back the running launchd service, the configured worker path, and worker PID 61081 with parent PID 60984. The total stop count was one. Hermes and Paseo were not stopped.

The production verification used a dedicated temporary credential over Tailscale HTTPS:

| Check | Result |
|---|---|
| Missing authentication | 401 |
| Route outside the voice scope | 403 |
| Invalid audio input | 400 |
| Haas speech recognition | 200, 991 ms |
| Qwen text cleanup | 200, 4611 ms |
| Self-revocation | 200 |
| Request after revocation | 401 |

All fields of the original 16 device records matched their pre-deployment hashes. The temporary credential was revoked; its retained record increased the total to 17 without changing the original records. The production verification reported no request text, audio, or token in the access log. The verification parent checked the saved seven-condition results, preservation and revocation results, and the live process relationship. The record contains no credential values or request bodies.

The operating procedure now requires readback of old-service removal and old-PID exit before bootstrap, and distinguishes a start-only recovery from another stop. This is a procedure correction; the installer implementation was not changed or retested by this documentation update. The initial failed start remains part of the result. State and evidence are owned by the same OS user and are not tamper-proof.

This closes the approved Bridge restart and server-side voice verification. Actual iPhone and MacBook voice acceptance remains separate and paused while the owner uses those devices.
