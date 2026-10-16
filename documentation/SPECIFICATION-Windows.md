# SPECIFICATION: Local LLM Checkup for Windows

Tool name: `Invoke-LocalLLMCheckup.ps1`
Language: PowerShell, compatible with Windows PowerShell 5.1 and PowerShell 7+
Target OS: Windows 10 (version 21H2 and later) and Windows 11
Version: 1.1.0

---

## 1. Purpose

Local AI on Windows often feels slow because the local server re-reads the whole prompt every turn when the KV prefix cache is not being hit. This tool checks the configuration that breaks the cache and proves, with a live test, whether the cache is working. It produces a markdown report (plus an HTML copy) with a results table, a score, and fix steps for every item that did not pass.

The tool never changes system or application configuration. It reports only.

## 2. Scope

### 2.1 Supported local servers

| Server | Default endpoint | Detection |
|---|---|---|
| Ollama | `http://localhost:11434` | `GET /api/tags` |
| LM Studio | `http://localhost:1234` | `GET /v1/models` |
| llama.cpp (`llama-server.exe`) | `http://localhost:8080` | `GET /v1/models` |

The user selects one server with `-Server`. If none is given, the tool probes all three and uses the first that responds. If none responds, the live test is skipped and the result is marked SKIP. A server named explicitly with `-Server` that does not respond is a tool error (exit 3) unless `-SkipLive` is set. When auto-detecting, the tool probes all three so the interactive picker (section 5.1) can offer a choice when more than one responds.

### 2.2 Out of scope

- Installing, updating, or configuring any software
- Benchmarking absolute tokens per second
- Hardware upgrade decisions
- Frontends other than Claude Code (see C4)
- WSL. Results for a Linux environment running under WSL should be taken from the Linux tool.

## 3. Checklist

The tool runs five checklist items (C1 to C5). Each produces one row in the results table with a result and a score.

### 3.1 Results and scoring

| Result | Meaning | Score |
|---|---|---|
| PASS | Check met | 1.0 |
| WARN | Works, but a likely cause of slow turns was found | 0.5 |
| FAIL | Check not met, and it breaks the prompt cache | 0.0 |
| SKIP | Not applicable (for example, Ollama not installed) | excluded |
| ERROR | The check could not run | excluded, reported |

The overall score is the mean of the scores of all items that were not skipped or errored, shown as a percentage. The report states how many items were excluded.

### 3.2 Items

| ID | Item | Method | PASS when | WARN when | FAIL when | SKIP when |
|---|---|---|---|---|---|---|
| C1 | Claude Code attribution header | Run `claude --version`; read the `CLAUDE_CODE_ATTRIBUTION_HEADER` variable from the process, user, and machine environment | Version is 2.1.181 or later, **or** the variable is set to `0` | Version is older, but the variable is not set and the version could not be parsed | Version is older than 2.1.181 and the variable is not `0` | Claude Code is not installed |
| C2 | Ollama context window | Run `ollama ps` and read the CONTEXT column of the loaded model. If no model is loaded, the live test loads one first. Also read the model's trained maximum context from `POST /api/show` (`model_info["<general.architecture>.context_length"]`, else any `*.context_length` key; `ollama show <model>` prints it as "context length"). Ollama never loads a model with more than this, so the setting cannot raise it. When the loaded context is below 64,000 and equals the maximum, the result thresholds are unchanged but the detail and recommendation change (see 7.3) | Context is 64,000 or more | Context is 32,000 to 63,999 | Context is below 32,000 | Ollama not installed or not the selected server |
| C3 | Hybrid model and prompt reprocessing | (a) Identify the model family against `hybrid-models.txt` shipped with the tool. (b) Search the server log for the phrase `full prompt reprocessing` | Model is not hybrid, **or** the log contains no reprocessing message | Model is hybrid but the log contains no reprocessing message yet | Log contains `full prompt reprocessing` in lines written during this run (the tool notes the log size, or journal cursor, at start and searches only what was added) | Log file not found and the model is not in the hybrid list |
| C4 | Frontend cache tokens | Live test: read the server's cache counter on request 2 (see section 4). If `-SessionLog` is given, also count cache-hit tokens reported in that log | Cached tokens on request 2 are at least 80% of the shared prefix | Counter not reported by the server, so the result is inferred from timing only; **or** cached tokens are 1% to 79% of the prompt | Cached tokens on request 2 are 0 while the prefix is identical | Live test skipped |
| C5 | Thinking tokens preserved between turns | Live test: three turns with reasoning enabled. Cached tokens must not decrease between turns | Cached tokens grow or stay the same on each turn | Cached tokens drop once but recover on the next turn | Cached tokens drop on two or more consecutive turns | Model does not produce reasoning output, or live test skipped |

### 3.3 Environment information (not scored)

The tool records these values in the report header:

- Windows edition, version, and build (`Get-CimInstance Win32_OperatingSystem`)
- CPU and installed memory (`Get-CimInstance Win32_Processor`, `Win32_ComputerSystem`)
- GPU name and VRAM where available (`Get-CimInstance Win32_VideoController`)
- PowerShell version (`$PSVersionTable.PSVersion`)
- Ollama, LM Studio, or llama.cpp version where available
- Claude Code version
- Selected server, endpoint, and model
- How the model was chosen (`CLI`, `config`, `interactive`, or `default`) and the config file path used, or "none"
- The model's trained maximum context (C2), or `n/a` if it cannot be read

## 4. Live cache test

The live test checks the server directly. It does not depend on any frontend.

1. Build a fixed prefix of about 4,000 tokens from a deterministic text block shipped with the tool. The same bytes are used on every run. The file is read with an explicit UTF-8 encoding and no BOM, so results match across machines.
2. Request 1: prefix plus question A. Record time to first token (TTFT), total time, and the prompt token count.
3. Request 2: the same prefix plus question B. Record the same values and the cached-token count.
4. Turns 3 and 4 (for C5): extend the conversation with the previous answer and a new question, keeping thinking enabled. Record cached-token counts.
5. Read the cache counter from the response in this order of preference: `usage.prompt_tokens_details.cached_tokens` (OpenAI-compatible responses), `timings.cache_n` (llama.cpp), then Ollama's `prompt_eval_cached_count` (reported by current Ollama versions alongside the full `prompt_eval_count`), and only if that is missing, `prompt_eval_count` compared with request 1's prompt length (older Ollama, where a small number means most of the prompt came from the cache). For Ollama, send requests to `/api/chat` with `keep_alive` (for example `10m`) so the model and its cache stay loaded between requests, and `think: true` when `/api/show` lists the `thinking` capability. If none is present, the result is inferred from TTFT and marked "server-side counter not reported".
6. Use `max_tokens` of 64 so the test runs quickly.
7. Requests are sent with `Invoke-RestMethod`. The tool sets a request timeout of 300 seconds so a slow cold read on a large model does not fail the check.

Decision details (as built in the macOS tool, and required for all three):

- C4 uses request 2's prompt token count as the size of the shared prefix (the differing question adds about 20 tokens). 80% or more cached is PASS, 1% to 79% is WARN, 0 is FAIL.
- C5 compares the cached-token counts of turns 2, 3 and 4: a drop from 2 to 3 or from 3 to 4 counts as one drop. One drop is WARN; drops on both is FAIL. If no turn produced reasoning output, C5 is SKIP.
- C2 with the live test skipped and no model loaded is SKIP.
- The live test leaves the model loaded for the `keep_alive` period; the 2-minute budget is measured from the end of request 1, so model load time is excluded.

Timing is reported for information only. Pass and fail decisions use cache counters, not timing, because timing varies with load.

## 5. Command line interface

```
Invoke-LocalLLMCheckup.ps1 [-Server <ollama|lmstudio|llamacpp>] [-Url <string>]
                           [-Model <string>] [-Log <path>] [-SessionLog <path>]
                           [-SkipLive] [-OutputDir <path>] [-NoColor] [-NoOpen]
                           [-ListModels] [-Interactive] [-Config <path>] [-Help] [-Version]
```

| Parameter | Description |
|---|---|
| `-Server` | Server to test. Default: auto-detect |
| `-Url` | Override the endpoint |
| `-Model` | Model to test, validated against the installed models. Default: first loaded model |
| `-ListModels` | List installed models for the selected or auto-detected server, then exit |
| `-Interactive` | Choose the server and model from a numbered menu (automatic in an interactive console when no model is given) |
| `-Config` | Config file (see 5.2) |
| `-NoOpen` | Do not open the HTML report at the end |
| `-Log` | Server log file for C3 and C4 |
| `-SessionLog` | Agent session log for C4 (optional) |
| `-SkipLive` | Run static checks only |
| `-OutputDir` | Report directory. Default: `.\reports` |
| `-NoColor` | Disable colours |

Default log locations checked when `-Log` is not given:

| Server | Default log location (Windows) |
|---|---|
| Ollama | `%LOCALAPPDATA%\Ollama\server.log` |
| LM Studio | `%USERPROFILE%\.lmstudio\server-logs\` (most recent file) |
| llama.cpp | none; the tool asks for `-Log` if the live test needs it |

### 5.1 Model listing and selection

- `-ListModels` lists the installed models of the selected or auto-detected server, with sizes where reported (Ollama `GET /api/tags`; LM Studio and llama.cpp `GET /v1/models`), then exits 0. It exits 3 if no server responds. Embedding models (for example `nomic-embed-text`, `all-minilm`, names containing `embed`, the Ollama `bert` family, or an LM Studio `type` of embeddings) are marked as not selectable.
- `-Model` is checked against the installed list. An unknown model prints an error plus the installed list and exits 3. For Ollama the name is accepted with or without `:latest`. An embedding model is rejected with exit 3.
- Interactive picker: `-Interactive` shows a numbered menu of installed non-embedding models (with sizes) and reads a number. Empty input chooses 1; out-of-range or non-numeric input re-prompts; end of input exits 3. If more than one server responded and none was configured, a server menu is shown first. The menu is drawn on the terminal, not standard output, so it never appears in piped output.
- The picker also runs automatically when the host is an interactive console and neither input nor output is redirected (`[Console]::IsInputRedirected` and `[Console]::IsOutputRedirected` are both false) and no model was given on the command line or in the config file. The tool never prompts when not attached to a terminal (scripts, pipes, CI); it falls back to the default model so scripted runs behave as before.
- Default model: the first loaded model (Ollama `GET /api/ps`), otherwise the first installed non-embedding model.
- The report records how the model was chosen: `CLI`, `config`, `interactive`, or `default`.

### 5.2 Config file

- Read from `-Config <path>` if given (unreadable file: exit 3), otherwise the first that exists of `local-llm-checkup.conf` next to the script, then `%APPDATA%\local-llm-checkup\config`.
- Format: plain `KEY=value` lines. Blank lines and lines starting with `#` are ignored. Values may be wrapped in matching single or double quotes; otherwise a trailing ` # comment` is removed.
- Keys: `SERVER`, `URL`, `MODEL`, `LOG`, `SESSION_LOG`, `OUTPUT`, `SKIP_LIVE`, `NO_COLOR`, `OPEN_REPORT`. Booleans accept 0/1, true/false, yes/no, on/off. Key names are case-insensitive.
- The file is parsed as text. It is never sourced, evaluated, or dot-included. Unknown keys and malformed lines produce a warning on stderr and are ignored.
- Precedence: command line, then config file, then auto-detect and built-in defaults.
- Ship `local-llm-checkup.conf.example` with every key commented out, and git-ignore the real config file.

## 6. Terminal output

- Colours use PowerShell's `$PSStyle` where available (PowerShell 7.2+), otherwise the ANSI escape sequence `` `e[ `` (PowerShell 7) or `[char]27` (Windows PowerShell 5.1). Windows Terminal and the classic console both render these.
- Colours: green for PASS, yellow for WARN, red for FAIL, dark grey for SKIP, cyan for headings and progress.
- Colours are turned off when `-NoColor` is set, when the `NO_COLOR` environment variable is set, or when the host is not an interactive console.
- Each check prints one line as it runs: `[C1] Claude Code attribution header ........ PASS`
- A progress line is shown during the live test.
- The final summary prints the overall score in colour and the paths to the markdown and HTML reports.
- At the end of a run, the tool opens the HTML report in the default browser with `Start-Process <report>.html` (or `Invoke-Item`). It does this only when standard output is an interactive terminal and the `CI` environment variable is not set, and never in pipes, scripts or CI. It also skips in a remote session (`$PSSenderInfo` set) and on non-Windows hosts. `-NoOpen` or `OPEN_REPORT=0` turns it off; `OPEN_REPORT=1` cannot force opening outside a terminal. If the HTML report was not written, nothing is opened. A failure to open prints an error to stderr and does not change the exit code.
- The tool sets `$ErrorActionPreference = 'Stop'` for its own logic and catches errors per check, so one failed check does not stop the others.

## 7. Report

The report is written to `<OutputDir>\llm-checkup-windows-<yyyyMMdd-HHmmss>.md`, encoded as UTF-8.

An HTML copy is written alongside it with the same base name and the `.html` extension (see 7.4).

### 7.1 Structure

1. Title and timestamp
2. Environment (section 3.3)
3. Summary: overall score, counts of PASS, WARN, FAIL, SKIP, ERROR
4. Results table
5. Live test details (request timings, cache counts per turn)
6. Recommendations, one subsection per item that is not PASS
7. Notes and limitations

### 7.2 Results table format

```markdown
| ID | Item | Result | Score | Detail |
|----|------|--------|-------|--------|
| C1 | Claude Code attribution header | FAIL | 0.0 | Claude Code 2.1.160, variable not set |
| C2 | Ollama context window | PASS | 1.0 | Context 65536 |
| C3 | Hybrid model and prompt reprocessing | WARN | 0.5 | Hybrid model, no reprocessing message yet |
| C4 | Frontend cache tokens | PASS | 1.0 | Cached 3,980 of 4,012 prefix tokens |
| C5 | Thinking tokens preserved | PASS | 1.0 | Cache grew on turns 2, 3, 4 |
| | **Overall** | | **60%** | 4 items scored, 0 skipped |
```

### 7.3 Recommendations

Each recommendation has four parts: what was found, why it matters, the steps to fix it on Windows, and how to verify the fix (re-run the tool). Steps use PowerShell commands and Windows paths. Where a setting can be changed in the Ollama app's Settings window, the recommendation names that option, and also gives the environment variable route.

Fix guidance for each item:

**C1 (Claude Code):**
- Run `claude update`, or reinstall using the official installer. Open a new PowerShell window afterwards so the updated binary is on the path.
- If an update is not possible, set the variable for your user account and restart the terminal:
  `[Environment]::SetEnvironmentVariable('CLAUDE_CODE_ATTRIBUTION_HEADER', '0', 'User')`
- If Claude Code is started from a shortcut or desktop launcher, quit it and start it again after setting the variable. Environment changes apply only to processes started after the change.

**C2 (Ollama context):**
- If the loaded context equals the model's trained maximum and that maximum is below 64,000, the detail reads `Context 32,768 = model maximum 32,768; setting cannot raise it` and these steps replace the ones below:
  - This model was trained with a maximum context of N tokens, and Ollama never loads it with more. Raising `OLLAMA_CONTEXT_LENGTH` will not change it.
  - Use a model with a larger trained context window (64,000 tokens or more) for agent sessions. Check a model's limit with `ollama show <model>` (the "context length" line) before choosing it.
  - Re-run the tool with that model (`-Model <model>` or the interactive picker) and confirm C2 shows PASS.
- Otherwise (loaded context below the maximum, or maximum unknown), use these steps. When the maximum is known, show it in the detail (for example `Context 32,768, minimum 64,000; model maximum 131,072`) and in the first step.
- Run `ollama ps` and note the CONTEXT column.
- Set the context length to at least 64000. Set the user environment variable:
  `[Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', '65536', 'User')`
  Then quit Ollama from the system tray icon and start it again. If your Ollama version has a context length option in its Settings window, you can use that instead.
- Run `ollama ps` again to confirm the new value. Ollama must reload the model before the change applies.
- Higher context uses more memory. Check Task Manager's Performance tab for GPU memory use after the change. If the model spills into system memory, choose a smaller model or a smaller context value.

**C3 (Hybrid model and reprocessing):**
- Find the log and search it: `Select-String -Path "$env:LOCALAPPDATA\Ollama\server.log" -Pattern "full prompt reprocessing"`.
- For llama.cpp, start `llama-server.exe` with `-v 4` (or `--verbosity 4`) to see the cache-related log lines.
- If the model is hybrid and reprocessing appears every turn, switch to a non-hybrid model for agent sessions, or accept the cold-read cost and keep sessions short.

**C4 (Frontend cache tokens):**
- Confirm the server reports cache counters. If it does not, update the server.
- Test the frontend itself: run a short agent session, then check the cache-token counter the server logs. Zero cached tokens deep into a session means the frontend is changing the prompt prefix between turns.
- Try another frontend that caches correctly, and compare the cache counter for the same task.

**C5 (Thinking tokens):**
- Find the setting in your frontend that controls whether reasoning output is kept in conversation history. Turn on preserved or kept thinking.
- If the frontend has no such setting, report the issue to its maintainer and consider a frontend that preserves thinking.
- Re-run the tool and confirm that cached tokens grow on each turn.

### 7.4 HTML report

- Written next to the markdown report: `llm-checkup-windows-<timestamp>.html`. Both paths are printed in the final summary.
- Generated with `ConvertFrom-Markdown` on PowerShell 7+ if available, otherwise a small built-in converter in PowerShell (required for Windows PowerShell 5.1); both are wrapped in the same HTML template. It converts exactly what the report uses: headings, paragraphs, bold, inline code, fenced code blocks, bullet lists, tables (including `\|` escaped inside cells) and links.
- Content is HTML-escaped (`&`, `<`, `>`) before formatting.
- Self-contained: `<meta charset="utf-8">`, inline CSS, no external assets or network access. Result cells show PASS (green), WARN (amber), FAIL (red), SKIP (grey) and ERROR (dark red) as coloured badges.
- If the HTML cannot be generated or written, the tool prints an error to stderr, keeps the markdown report, and does not change the exit code.
- The live test details also show `Loaded context (ollama ps): X; model trained maximum: Y` for Ollama.

## 8. Exit codes

| Code | Meaning |
|---|---|
| 0 | All scored items PASS |
| 1 | At least one WARN, no FAIL |
| 2 | At least one FAIL |
| 3 | Tool error: missing dependency, bad arguments, unreadable config file, unknown or embedding model, no server for `-ListModels`, end of input at the interactive picker, or a server named with `-Server` that is unreachable while `-SkipLive` is not set |

## 9. Dependencies

Required: Windows PowerShell 5.1 or PowerShell 7+, and the built-in CIM cmdlets.

Optional tools used when present: `ollama`, `claude`, and `llama-server.exe` on the PATH. The tool does not require them unless the matching server is selected.

The tool never installs software. If a required component is missing, it prints the install step and exits with code 3.

## 10. Execution policy

The tool is an unsigned script. If the policy blocks it, the tool prints this command and exits with code 3:

`powershell -ExecutionPolicy Bypass -File .\Invoke-LocalLLMCheckup.ps1`

It does not change the execution policy itself.

## 11. Acceptance criteria

1. Runs on Windows 10 21H2 and later, and Windows 11, under both Windows PowerShell 5.1 and PowerShell 7+.
2. Produces a valid markdown report containing the results table, score, and a recommendation for every non-PASS item.
3. Terminal output is coloured, and colour can be turned off as specified in section 6.
4. Makes no changes to any configuration, environment variable, or application setting.
5. Live test uses identical prefix bytes on every run, read as UTF-8 without BOM.
6. Exit codes match section 8.
7. Each recommendation names the Windows-specific command, path, or settings option required.
8. A failing check does not stop the remaining checks.
9. `-ListModels`, `-Model` validation, the interactive picker and the config file behave as in section 5.1 and 5.2, and the tool never prompts without a terminal.
10. An HTML copy of the report is written as in section 7.4, and failure to write it does not change the markdown report or the exit code.
11. The HTML report opens at the end only in an interactive terminal outside CI, and `-NoOpen` / `OPEN_REPORT=0` disable it.
