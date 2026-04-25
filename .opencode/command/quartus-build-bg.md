---
description: Start, monitor, or rejoin a background Quartus build
---

## User Input

```text
$ARGUMENTS
```

Use `scripts/quartus-build-bg.sh` to manage the build. If `$ARGUMENTS` is empty, start a new background build.

Supported arguments:

- `start`: start the build in the background.
- `start --force`: stop an existing background build first, then start a new one.
- `status`: show current build status, PID, timestamps, log path, and bitstream path.
- `wait`: wait for the background build to finish, print status/timing, and continue this OpenCode session with the result.
- `log`: print the captured build log.
- `stop`: stop the running background build.

## Procedure

1. From the repo root, run `scripts/quartus-build-bg.sh <arguments>` using the Bash tool.
2. If no arguments were provided, run `scripts/quartus-build-bg.sh start`.
3. After `start`, tell the user the build is running in the background and that the session can continue. Mention `scripts/quartus-build-bg.sh wait` as the rejoin command.
4. After `wait`, inspect the exit code and timing summary. If the command fails, use `scripts/quartus-build-bg.sh log` or the printed log path to summarize the failure.
5. Do not run the normal foreground `scripts/build.sh` unless the user explicitly asks for a blocking build.
