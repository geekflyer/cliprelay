# AGENTS Instructions

## Git Policy Override for OpenCode
After completing any significant code change (new feature, bug fix, refactor), 
you MUST immediately stage and commit with a conventional commit message.
Do NOT wait for the user to ask you to commit. This overrides the default 
"only commit when requested" policy.

## Commit Authorization
- For this repo, every user request that results in code or documentation changes is explicit authorization to create a commit.
- Do not wait for a separate "please commit" instruction.
- When the worktree has unrelated changes, commit only files relevant to the task.

## Build Verification
- After completing any set of code changes, ALWAYS run a rebuild using scripts/build-all.sh before reporting completion.
- Use the project build script when available.
- If a full rebuild is not possible, run the closest relevant target build and clearly report what was run and what could not be run.

## Integration Tests
- After every major code change (new feature, bug fix, refactor), run the full test suite using `scripts/test-all.sh` before committing.
- If any tests fail, fix the failures before committing or reporting completion.
- If the test suite cannot be run (e.g., missing toolchain), clearly report which tests were skipped and why.

## Hardware Integration Tests
- After every major code change, check if an Android device is connected by running `adb get-state 2>/dev/null`.
- If a device is connected (output is "device"), run the automated BLE hardware smoke tests using `scripts/hardware-smoke-test.sh` before committing.
- If the hardware tests fail, fix the failures before committing or reporting completion.
- If no Android device is connected, skip the hardware tests and report that they were skipped due to no device being available.

## App Restart After Code Changes
- After every major code change (new feature, bug fix, refactor), restart both apps so the user can immediately verify the fix:
  - **Mac**: Kill any running ClipRelay process (`pkill -f ClipRelay`) and relaunch with `open dist/ClipRelay.app`
  - **Android**: Install the new APK (`adb install -r dist/cliprelay-debug.apk`), force-stop the app (`adb shell am force-stop com.cliprelay`), and relaunch (`adb shell am start -n com.cliprelay/.ui.MainActivity`)
- Do not skip this step or tell the user to do it manually.

## Auto-Commit
- After completing a major set of code changes (new feature, bug fix, refactor, etc.) and verifying the build passes, automatically create a git commit and push it.
- Use a concise, descriptive commit message summarizing the changes.
- Do not wait for the user to ask for a commit — proactively commit and push after each logical unit of work.
