# Agent Instructions

These instructions are for Codex and other AI coding agents working in this
repository.

## Windows / PowerShell Environment

- Do not assume Japanese text is corrupted just because terminal output looks
  garbled. Treat that as an output decoding/display problem until proven
  otherwise.
- When checking files that contain Japanese, read them explicitly as UTF-8:

```powershell
Get-Content -Encoding UTF8 path\to\file
```

- If corruption is suspected, verify through more than one route before saying
  the file itself is mojibake. Prefer UTF-8 reads, `git diff`, and byte-level
  checks over terminal appearance alone.
- Preserve existing Japanese text. Do not "fix" Japanese text solely because a
  shell command rendered it badly.

## Searching

- `ripgrep` is installed through winget in this user profile, but this Codex
  Windows environment may initially resolve `rg` to the Codex app bundled path
  under `C:\Program Files\WindowsApps\OpenAI.Codex_...\app\resources`, which can
  fail with `Access is denied`.
- Before using `rg` in a fresh session, verify it:

```powershell
rg --version
```

- If `rg` fails with `Access is denied`, prepend the user PATH for the current
  shell and retry:

```powershell
$env:Path = "$([Environment]::GetEnvironmentVariable('Path','User'));$env:Path"
rg --version
```

- If `rg` is still unavailable, use PowerShell-native search instead:

```powershell
Get-ChildItem -Recurse -File
Select-String -Path path\to\files -Pattern "keyword"
```
