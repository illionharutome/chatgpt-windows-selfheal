# ChatGPT Windows Self-Heal

A small, unofficial Windows recovery launcher for a specific Microsoft Store / MSIX ChatGPT (OpenAI.Codex) startup failure where the app starts only as background processes and no window appears because the bundled `cua_node` runtime fails to materialize from `WindowsApps` into `%LOCALAPPDATA%`.

> **Unofficial community workaround.** This project is not affiliated with or endorsed by OpenAI. It is intentionally narrow: it targets the `cua_node` runtime relocation/finalization failure discussed in [`openai/codex#41540`](https://github.com/openai/codex/issues/41540).

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

The observed failure chain is:

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
3. Computes the current runtime ID from the live installation; no OpenAI.Codex version or runtime ID is hard-coded.
4. Checks whether the final runtime is healthy.
5. If healthy, launches ChatGPT immediately.
6. If missing/incomplete, stops the existing ChatGPT process tree, copies the runtime into a temporary repair directory with `xcopy /G`, validates the copied file tree, and only then promotes it to the final runtime directory.
7. Cleans failed staging/repair directories only for the current runtime ID after a verified repair.
8. Launches the MSIX app through the registered AppX identity.

The script does **not** take ownership of `WindowsApps`, modify ACLs, disable EFS/Application Protection, modify package files, reset the app, or delete the whole OpenAI local-data directory.

## Runtime ID algorithm

Static analysis of the shipped desktop bundle showed the runtime ID is derived from these files, in this order:

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

## Requirements

- Windows 11
- Microsoft Store / MSIX ChatGPT desktop package named `OpenAI.Codex`
- Windows PowerShell 5.1 or PowerShell 7+

This is **not** intended for macOS or unrelated ChatGPT startup failures.

## Install

Download these two files into the same folder:

```text
ChatGPT-SelfHeal.ps1
ChatGPT-SelfHeal.cmd
```

Then double-click:

```text
ChatGPT-SelfHeal.cmd
```

You can create a normal desktop shortcut to the `.cmd` file and use it as your ChatGPT launcher.

## First-run dry test

Before the first repair, you can run a read-only check:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\ChatGPT-SelfHeal.ps1" -DryRun
```

`-DryRun` does not stop processes, copy/promote runtimes, clean staging directories, or launch ChatGPT. It still writes a diagnostic log under `%LOCALAPPDATA%\OpenAI\Codex\selfheal\`.

A healthy result looks roughly like:

```text
[1/6] Detect ChatGPT version
[2/6] Detect cua_node runtime
runtime-id : <16 hex chars>
runtime healthy : yes
repair required : no
```

## Repair behavior

When repair is required, the script uses this transaction-like flow:

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

Validation checks:

- source and target file counts
- missing relative paths
- extra relative paths
- file-size mismatches
- SHA-256 for `manifest.json`, `bin/node.exe`, and `bin/node_repl.exe`

If an invalid final runtime already exists, it is renamed to `.backup-*` before promotion. If promotion or post-promotion validation fails, the script attempts to roll back the previous final runtime.

## Safety notes

- The repair path can take several minutes because `xcopy /G` may need to materialize thousands of protected/encrypted package files.
- Do not close the repair window while a full copy is running.
- The script only stops `ChatGPT.exe` and its current child process tree; it does not globally kill every `codex.exe` process on the machine.
- Old `.backup-*` directories are deliberately preserved for manual inspection and are not automatically deleted.
- Repair logs are written to:

  ```text
  %LOCALAPPDATA%\OpenAI\Codex\selfheal\
  ```

## Uninstall

Delete:

```text
ChatGPT-SelfHeal.ps1
ChatGPT-SelfHeal.cmd
```

Optionally delete the self-heal logs under `%LOCALAPPDATA%\OpenAI\Codex\selfheal\`.

No service, scheduled task, registry entry, or persistent background process is installed.

## Related upstream issue

The underlying Desktop behavior has been investigated in the OpenAI Codex issue tracker:

- [`openai/codex#41540`](https://github.com/openai/codex/issues/41540)
- Related reports include `#41654` and `#40843`.

The proper long-term fix belongs upstream in the Windows desktop runtime-relocation implementation. This project is a user-side recovery mechanism until that path is fixed.

## 中文说明

这是一个针对 **Windows Microsoft Store / MSIX 版 ChatGPT** 特定启动故障的一键自愈启动器。

适用现象主要包括：

- 点击 ChatGPT 后只有后台进程，没有窗口；
- `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node` 不断生成 `.staging-*`；
- 更新客户端后 runtime-id 改变，问题再次出现；
- 手工使用 `xcopy /G` 完整 materialize `cua_node` 后可以恢复启动。

使用前建议先执行 `-DryRun`。如果 runtime 正常，脚本不会重复复制；只有检测到当前 runtime 缺失或不完整时才进入修复流程。

本工具不会修改 `WindowsApps` 权限、不会 `takeown`、不会关闭 EFS、不会重置/重装 ChatGPT，也不会删除整个 OpenAI 本地数据目录。

## License

MIT. See [LICENSE](LICENSE).
