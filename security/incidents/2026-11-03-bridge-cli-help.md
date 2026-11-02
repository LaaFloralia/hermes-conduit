# Bridge CLI: help unexpectedly issued a pairing code

At 05:55 JST on 2026-11-03, the parent ran `laa-bridge pair --help` while preparing the owner's MacBook connection. The CLI parsed the flag but still invoked `commandPair`, issuing a valid one-time code and returning it in the tool output. The value is not reproduced here.

The parent identified the exact pairing by its creation and expiry timestamps. It was unused and had no device ID. Through the existing store's locked, atomic mutation, only that pairing's expiry was moved into the past. Readback confirmed `unused=true`, `expired=true`, and `deviceCreated=false`. No existing device, service, or worker was stopped or revoked. The historical tool output remains; its code is no longer usable.

The CLI now handles `--help` and `-h` before dispatch and lets stdout drain normally. Unexpected positional input to `pair`, including `pair help`, exits without issuing a code. Isolated regression tests cover all commands, task restore/import help, existing-state preservation, and absent-state preservation. The original `pair --help` regression failed before the fix; the CLI-focused suite passed 40/40 after the changes.

An existing official DSH DeepSeek High subagent independently reviewed only the changed CLI and test, with no access to production state or credentials. Its initial review identified the short-option and absent-state gaps, which were corrected. The final independent review confirmed the corrections and repeated the focused suite: 40/40 passed. The production CLI is a wrapper to this checkout, so help dispatch takes effect without restarting the Bridge. Git publication is tracked in this file’s commit history.

Scope: this corrects help dispatch, not the Bridge's authorization model. State and evidence are owned by the same OS user and are not tamper-proof.
