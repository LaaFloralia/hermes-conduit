# LAA Conduit project rules

- The owner assigns iOS implementation to GPT-6.1 Terra at max effort and independent reviews to DeepSeek V4.1 Flash at max effort.
- Design and verify first for the owner's single-screen iPhone 16 Pro Max (440 × 956 pt). iPhone Duo is optional.
- On this Mac, the installed iOS 27.1 simulator runtime supports only iPhone Duo. Verify iPhone layouts with compact 440 × 956 pt snapshot tests, such as `LAACompactChatSnapshotTests`, then on the real device through TestFlight. Do not add simulator runtimes without the parent session's approval.
- Across the shared Mac, run at most three concurrent `xcodebuild` processes, each with `-jobs 4`. Boot only one simulator at a time and shut it down immediately after testing. Check `laa-storage-guard status` and keep at least 80 GiB free.
- Merge one candidate at a time. Require GitHub CI and the LAA personal build on the candidate. GitHub CI selects tests with `--changed-from HEAD^1`; integration candidates also require the selected smoke tests locally with `--changed-from <master SHA>`.
- On Duo, the known local smoke baselines are five `ConnectionSetupUITests` failures caused by a saved profile and one `ProfilePickerUITests` failure caused by a probe outside the window. New failures block the merge.
- If GitHub Actions is unavailable, gate on the local master-based smoke with no new failures and a local personal Release build: generate `project-personal.yml` and build for generic iOS with `CODE_SIGNING_ALLOWED=NO`.
- The parent session runs TestFlight uploads because it holds the required secrets.
- Install launchd services such as the push relay (`scripts/laa/relay-install.sh`) only from the main checkout `/Users/laa/dev/hermes-conduit`, never from a worktree; worktrees are removed after merges.
- Conduit plugin updates are decided by the daily HQ routine in `hq/tools/CONDUIT-UPDATE.md`. The LAA build shows no plugin update notices.
