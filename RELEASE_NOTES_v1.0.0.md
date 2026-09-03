# v1.0.0

Initial public release of ChatGPT Windows Self-Heal.

## What it fixes

A narrow Windows Microsoft Store/MSIX ChatGPT (`OpenAI.Codex`) startup failure where `ChatGPT.exe` remains in the background with no visible window because the bundled `cua_node` runtime cannot be fully materialized from `WindowsApps` into `%LOCALAPPDATA%`.

## Highlights

- Dynamically detects the installed `OpenAI.Codex` package.
- Dynamically computes the current `cua_node` runtime ID; no version/runtime ID is hard-coded.
- Repairs only when the final runtime is missing or unhealthy.
- Copies with `xcopy /G` into a temporary `.repair-*` directory.
- Validates file count, relative paths, sizes, and critical-file SHA-256 values before promotion.
- Preserves/rolls back an existing invalid final runtime if promotion fails.
- Does not take ownership of `WindowsApps`, modify ACLs, disable EFS, or reset/reinstall ChatGPT.
- Does not globally kill unrelated `codex.exe` sessions.
- Includes a `-DryRun` diagnostic mode.

## Related upstream issue

- https://github.com/openai/codex/issues/41540

## Caveat

This is an unofficial user-side workaround. The durable fix belongs in the upstream Windows Desktop runtime-relocation implementation.

A possible correlation with Store/MSIX packages physically located on a secondary AppxVolume has been observed in related reports, but this is **not confirmed as the root cause**. Windows may expose such packages through a managed `C:\Program Files\WindowsApps` path even when the backing AppxVolume is on another drive.