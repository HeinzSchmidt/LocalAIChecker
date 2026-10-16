# Local LLM Checkup for Windows

`Invoke-LocalLLMCheckup.ps1` checks whether your local LLM server on Windows is hitting its
KV prefix cache, which is the most common reason local AI agents feel slow. It inspects the
settings that break the cache, runs a short live test against the server, and writes a
markdown report plus an HTML copy, with a score and Windows fix steps for anything that did
not pass.

It **never changes** configuration, environment variables or application settings.
Implements [`documentation/SPECIFICATION-Windows.md`](../documentation/SPECIFICATION-Windows.md) v1.1.0
and matches the macOS tool feature for feature.

## Requirements

- Windows 10 21H2+ or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+. No modules and no `jq`: JSON is handled with `ConvertFrom-Json`.
- One local server: Ollama (`:11434`), LM Studio (`:1234`) or llama.cpp `llama-server.exe` (`:8080`)

## Files

| File | Purpose |
|---|---|
| `Invoke-LocalLLMCheckup.ps1` | The tool |
| `hybrid-models.txt` | Hybrid / SSM model-name patterns for C3 (same file as macOS) |
| `prefix.txt` | Fixed ~3,800-token prefix. Same bytes as `MacOS/prefix.txt` (sha256 `df940c7c…0dea`); do not edit |
| `local-llm-checkup.conf.example` | Example config file |
| `reports\` | Default report directory (git-ignored) |

## Usage

The script is unsigned. If your execution policy blocks it, run it with a one-off bypass;
the tool never changes the policy itself:

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-LocalLLMCheckup.ps1 [options]
```

```
  -Server <ollama|lmstudio|llamacpp>  Server to test (default: auto-detect)
  -Url <url>                          Override endpoint (requires -Server)
  -Model <name>                       Model to test (validated against installed models)
  -Interactive                        Choose server and model from a menu
  -ListModels                         List installed models and exit
  -Config <path>                      Config file
  -Log <path>                         Server log file for C3
  -SessionLog <path>                  Agent session log for C4 (optional)
  -SkipLive                           Run static checks only
  -OutputDir <path>                   Report directory (default: .\reports)
  -NoColor                            Disable colours
  -NoOpen                             Do not open the HTML report in the browser
  -Help                               Show help
  -Version                            Show version
```

Examples:

```powershell
.\Invoke-LocalLLMCheckup.ps1                          # auto-detect; menu if no model configured
.\Invoke-LocalLLMCheckup.ps1 -ListModels              # installed models (embedding models marked)
.\Invoke-LocalLLMCheckup.ps1 -Model qwen2.5:3b        # test a specific Ollama model
.\Invoke-LocalLLMCheckup.ps1 -SkipLive                # static checks only
.\Invoke-LocalLLMCheckup.ps1 -Server llamacpp -Log C:\logs\llama.log
$env:NO_COLOR = 1; .\Invoke-LocalLLMCheckup.ps1 -NoOpen
```

The script parses its own arguments, so a bad or incomplete option always exits 3. Ordinary
PowerShell parameter binding would exit 1 instead.

## Model selection and config file

These behave the same as on macOS:
- `-ListModels` lists the installed models.
- `-Model` is checked against them; `:latest` is optional for Ollama, and an unknown or embedding model exits 3.
- The interactive picker opens automatically in an interactive console when no model is configured. It never prompts when input or output is redirected.
- Config precedence is command line > config file > auto-detect.

The config file is `-Config <path>`, else `local-llm-checkup.conf` next to the script, else
`%APPDATA%\local-llm-checkup\config`. It uses `KEY=value` lines with keys `SERVER`, `URL`,
`MODEL`, `LOG`, `SESSION_LOG`, `OUTPUT`, `SKIP_LIVE`, `NO_COLOR` and `OPEN_REPORT`. The tool
reads it as text and never dot-sources it. The report records how the model was chosen.

## Checks, live test and exit codes

These match the macOS tool and the specification:
- **C1:** Claude Code version, or `CLAUDE_CODE_ATTRIBUTION_HEADER=0` in the process, user or machine environment.
- **C2:** `ollama ps` CONTEXT plus the model's trained maximum from `/api/show`.
- **C3:** hybrid list, and `full prompt reprocessing` in log lines written during this run. The default log is `%LOCALAPPDATA%\Ollama\server.log`.
- **C4:** cache counter on request 2. 80% or more is PASS, 1–79% is WARN, 0 is FAIL.
- **C5:** turns 2→3→4.

The live test makes four streamed requests with max_tokens 64. Counters are read in this order: `usage.prompt_tokens_details.cached_tokens`, `timings.cache_n`, Ollama `prompt_eval_cached_count`, then `prompt_eval_count`. Requests use `HttpWebRequest` so time to first token can be measured on the stream in both 5.1 and 7; `Invoke-RestMethod` handles everything else.

Exit codes: 0 all scored items PASS, 1 WARN (no FAIL), 2 at least one FAIL, 3 tool error.

## Reports

- `reports\llm-checkup-windows-<yyyyMMdd-HHmmss>.md` is written as UTF-8 without BOM.
- A `.html` copy is written next to it: self-contained, with coloured PASS/WARN/FAIL/SKIP/ERROR badges. PowerShell 7 uses `ConvertFrom-Markdown` and adds the badges; Windows PowerShell 5.1 uses the built-in converter.
- If the HTML fails, the error goes to stderr and the markdown report and exit code are unchanged.
- At the end of an interactive run, the HTML report opens with `Start-Process`. It doesn't open when output is redirected, when `CI` is set, in a remote session, or with `-NoOpen` / `OPEN_REPORT=0`.

## Verification status

This tool was developed on a non-Windows machine. The following were run under PowerShell 7.4.6 on Linux:
- parser and PSScriptAnalyzer
- `-Help`, `-Version`, bad arguments, `-ListModels`, `-Model` validation, config precedence, `-SkipLive`
- the interactive menu, via a pseudo-terminal
- a full live run against a local Ollama
- the HTML failure path

**Not yet run on Windows:**
- Windows PowerShell 5.1
- the CIM environment queries
- the `User`/`Machine` environment lookup for C1
- `%LOCALAPPDATA%\Ollama\server.log` detection
- `Start-Process` opening the report
- the 5.1 code path of the HTML converter (it was tested under 7 by calling it directly)
