# ChatGPT Windows Self-Heal

Unofficial Windows recovery launcher for a specific Microsoft Store / MSIX ChatGPT (`OpenAI.Codex`) startup failure: the app starts only as background processes and no window appears because the bundled `cua_node` runtime fails to materialize from `WindowsApps` into `%LOCALAPPDATA%`.

> **Unofficial community workaround.** This project is not affiliated with or endorsed by OpenAI. It targets the `cua_node` runtime relocation/finalization failure discussed in [`openai/codex#41540`](https://github.com/openai/codex/issues/41540).

## Quick start

**Current public snapshot: v1.0.0**

- **[Download v1.0.0 ZIP](https://github.com/illionharutome/chatgpt-windows-selfheal/raw/main/dist/ChatGPT-Windows-SelfHeal-v1.0.0.zip)** — recommended
- [Download `ChatGPT-SelfHeal.ps1`](https://raw.githubusercontent.com/illionharutome/chatgpt-windows-selfheal/main/ChatGPT-SelfHeal.ps1)
- [Download `ChatGPT-SelfHeal.cmd`](https://raw.githubusercontent.com/illionharutome/chatgpt-windows-selfheal/main/ChatGPT-SelfHeal.cmd)
- [v1.0.0 release notes](RELEASE_NOTES_v1.0.0.md)
- [Related upstream issue: openai/codex#41540](https://github.com/openai/codex/issues/41540)

Extract the ZIP (or put the `.ps1` and `.cmd` files in the same folder), then double-click:

```text
ChatGPT-SelfHeal.cmd
```

For a diagnostic-only first run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\ChatGPT-SelfHeal.ps1" -DryRun
```

`-DryRun` does not stop processes, copy/promote runtimes, clean staging directories, or launch ChatGPT. It still writes a diagnostic log under `%LOCALAPPDATA%\OpenAI\Codex\selfheal\`.

## Symptoms this tool targets

Typical affected systems show all or most of the following:

- Clicking ChatGPT creates `ChatGPT.exe` background processes but no visible window.
- `MainWindowHandle` remains `0`.
- `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node` repeatedly accumulates directories such as:

  ```text
  .staging-<runtime-id>-XXXXXX
  ```

- The corresponding final runtime directory `<runtime-id>` is missing or incomplete.
- The failure returns after an OpenAI.Codex update changes the bundled runtime ID.

Observed failure chain:

```text
WindowsApps protected cua_node files
        ↓
runtime relocation/materialization fails
        ↓
.staging-* never finalizes
        ↓
app-server / renderer do not start normally
        ↓
background ChatGPT.exe processes, no window
```

## What this tool does

`ChatGPT-SelfHeal.ps1` dynamically:

1. Finds the installed `OpenAI.Codex` MSIX package with `Get-AppxPackage`.
2. Locates the current bundled `app\resources\cua_node` runtime.
3. Computes the current runtime ID from the live installation; no package version or runtime ID is hard-coded.
4. Checks whether the final runtime is healthy.
5. If healthy, launches ChatGPT immediately.
6. If missing/incomplete, stops the current ChatGPT process tree, copies the runtime into a temporary `.repair-*` directory with `xcopy /G`, validates the copied file tree, and only then promotes it to the final runtime directory.
7. Cleans failed staging/repair directories only for the current runtime ID after a verified repair.
8. Launches the MSIX app through its registered AppX identity.

The script does **not** take ownership of `WindowsApps`, modify ACLs, disable EFS/Application Protection, modify package files, reset the app, or delete the whole OpenAI local-data directory.

## Runtime ID algorithm

Static analysis of the shipped Desktop bundle showed that the runtime ID is derived from these files, in this order:

```text
manifest.json
bin/node.exe
bin/node_repl.exe
```

For each file:

```text
digest = sha256hex(file contents)
```

Then:

```text
runtime-id = sha256hex(
  name + NUL + digest + NUL
  ... repeated for all three files ...
)[0:16]
```

If this algorithm stops matching a future OpenAI.Codex build, the script fails safely instead of guessing an ID from stale staging directories.

## Repair behavior

When repair is required:

```text
WindowsApps\...\cua_node
        ↓ xcopy /G
.repair-<runtime-id>-<random>
        ↓ validate complete file tree
        ↓ same-volume rename
<runtime-id>
        ↓
launch ChatGPT
```

Validation checks include:

- source and target file counts
- missing relative paths
- extra relative paths
- file-size mismatches
- SHA-256 for `manifest.json`, `bin/node.exe`, and `bin/node_repl.exe`

If an invalid final runtime already exists, it is renamed to `.backup-*` before promotion. If promotion or post-promotion validation fails, the script attempts to roll back the previous final runtime.

## Possible secondary AppxVolume correlation — unconfirmed

There is a **possible** correlation between this bug and Microsoft Store/MSIX packages that are physically stored on a secondary AppxVolume / non-system drive.

One affected report in the upstream issue describes the package being physically stored under `D:\WindowsApps` while Windows exposed the package through a managed path under `C:\Program Files\WindowsApps`. That configuration also reproduced the `Application Protected` / `ERROR_ENCRYPTION_FAILED` behavior.

This is **not proven to be the root cause**. In particular, the visible `Get-AppxPackage ... InstallLocation` may still show `C:\Program Files\WindowsApps` even when the physical backing AppxVolume is elsewhere. If you are collecting diagnostics, useful data points include:

- actual AppxVolume / physical package backing volume
- whether ChatGPT was moved to another drive through Windows/Store settings
- source and `%LOCALAPPDATA%` destination volumes/filesystems
- `cipher /c` output for affected bundled runtime files
- the exact Win32 error from the failing copy/fallback path

## Requirements

- Windows 11
- Microsoft Store / MSIX ChatGPT Desktop package named `OpenAI.Codex`
- Windows PowerShell 5.1 or PowerShell 7+

This tool is **not** intended for macOS or unrelated ChatGPT startup failures.

## Safety notes

- A repair can take several minutes because `xcopy /G` may need to materialize thousands of protected/encrypted package files.
- Do not close the repair window during a full copy.
- The script only stops `ChatGPT.exe` and its current child process tree; it does not globally kill every `codex.exe` process on the machine.
- Old `.backup-*` directories are deliberately preserved for manual inspection.
- Logs are written to `%LOCALAPPDATA%\OpenAI\Codex\selfheal\`.

## Uninstall

Delete `ChatGPT-SelfHeal.ps1` and `ChatGPT-SelfHeal.cmd`. Optionally remove the self-heal log directory. No service, scheduled task, registry entry, or persistent background process is installed.

## 中文说明

这是一个针对 **Windows Microsoft Store / MSIX 版 ChatGPT** 特定启动故障的一键自愈启动器。

适用现象主要包括：点击 ChatGPT 后只有后台进程没有窗口、`cua_node` 目录持续产生 `.staging-*`、更新后 runtime-id 改变并再次复发，以及手工使用 `xcopy /G` 完整 materialize `cua_node` 后可以恢复启动。

此外，目前存在一个**尚未证实的相关性假设**：如果 Microsoft Store/MSIX 包实际位于非系统盘的 AppxVolume，上述 `Application Protected` 文件复制问题可能更容易暴露。Windows 仍可能把包显示在 `C:\Program Files\WindowsApps` 管理路径下，因此不能仅凭 `InstallLocation` 判断实际物理盘。这个因素目前只应作为排查维度，不应表述为已确认根因。

本工具不会修改 `WindowsApps` 权限、不会 `takeown`、不会关闭 EFS、不会重置/重装 ChatGPT，也不会删除整个 OpenAI 本地数据目录。

## Related upstream issues

- [`openai/codex#41540`](https://github.com/openai/codex/issues/41540)
- Related reports: `#41654`, `#40843`

The durable fix belongs upstream in the Windows Desktop runtime-relocation implementation.

## License

MIT. See [LICENSE](LICENSE).
