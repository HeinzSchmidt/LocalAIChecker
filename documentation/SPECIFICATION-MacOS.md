# SPECIFICATION: Local LLM Checkup for macOS

Tool name: `local-llm-checkup.sh`
Language: Bash (3.2 compatible, the default shell on macOS), with standard macOS utilities only
Target OS: macOS 14 (Sonoma) and later, Apple Silicon (M-series) required
Version: 1.1.0

---

## 1. Purpose

Local AI on a Mac often feels slow because the local server re-reads the whole prompt on every turn when the KV prefix cache is not being hit. This tool checks the configuration that breaks the cache and proves, with a live test, whether the cache is working. It produces a markdown report (plus an HTML copy) with a results table, a score, and fix steps for every item that did not pass.

The tool never changes system or application configuration. It reports only.

## 2. Scope

### 2.1 Supported local servers

| Server | Default endpoint | Detection |
|---|---|---|
| Ollama | `http://localhost:11434` | `GET /api/tags` |
| LM Studio | `http://localhost:1234` | `GET /v1/models` |
| llama.cpp (`llama-server`) | `http://localhost:8080` | `GET /v1/models` |

The user selects one server with `--server`. If none is given, the tool probes all three and uses the first one that responds. If none responds, the live test is skipped and the result is marked SKIP. A server named explicitly with `--server` that does not respond is a tool error (exit 3) unless `--skip-live` is set. When auto-detecting, the tool probes all three so the interactive picker (section 5.1) can offer a choice when more than one responds.

### 2.2 Out of scope

- Installing, updating, or configuring any software
- Benchmarking absolute tokens per second
- Checking hardware upgrade decisions
- Inspecting frontends other than Claude Code (see C4 for how frontends are handled)

## 3. Checklist

The tool runs five checklist items (C1 to C5). Each item produces one row in the results table with a result and a score.

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
| C1 | Claude Code attribution header | Run `claude --version`; read `CLAUDE_CODE_ATTRIBUTION_HEADER` from the environment | Version is 2.1.181 or later, **or** the variable is set to `0` | Version is older, but the variable is not set and the version could not be parsed | Version is older than 2.1.181 and the variable is not `0` | Claude Code is not installed |
| C2 | Ollama context window | Run `ollama ps` and read the CONTEXT column of the loaded model. If no model is loaded, the live test loads one first. Also read the model's trained maximum context from `POST /api/show` (`model_info["<general.architecture>.context_length"]`, else any `*.context_length` key; `ollama show <model>` prints it as "context length"). Ollama never loads a model with more than this, so the setting cannot raise it. When the loaded context is below 64,000 and equals the maximum, the result thresholds are unchanged but the detail and recommendation change (see 7.3) | Context is 64,000 or more | Context is 32,000 to 63,999 | Context is below 32,000 | Ollama not installed or not the selected server |
| C3 | Hybrid model and prompt reprocessing | (a) Identify the model family against `hybrid-models.txt` shipped with the tool. (b) Search the server log for the phrase `full prompt reprocessing` | Model is not hybrid, **or** the log contains no reprocessing message | Model is hybrid but the log contains no reprocessing message yet | Log contains `full prompt reprocessing` in lines written during this run (the tool notes the log size, or journal cursor, at start and searches only what was added) | Log file not found and the model is not in the hybrid list |
| C4 | Frontend cache tokens | Live test: read the server's cache counter on request 2 (see section 4). If `--session-log` is given, also count cache-hit tokens reported in that log | Cached tokens on request 2 are at least 80% of the shared prefix | Counter not reported by the server, so the result is inferred from timing only; **or** cached tokens are 1% to 79% of the prompt | Cached tokens on request 2 are 0 while the prefix is identical | Live test skipped |
| C5 | Thinking tokens preserved between turns | Live test: three turns with reasoning enabled. Cached tokens must not decrease between turns | Cached tokens grow or stay the same on each turn | Cached tokens drop once but recover on the next turn | Cached tokens drop on two or more consecutive turns | Model does not produce reasoning output, or live test skipped |

### 3.3 Environment information (not scored)

Before the checklist runs, the tool records these values in the report header:

- macOS version (`sw_vers -productVersion`)
- Chip and memory (`sysctl -n machdep.cpu.brand_string`, `sysctl -n hw.memsize`)
- Ollama, LM Studio, or llama.cpp version where available
- Claude Code version
- Selected server, endpoint, and model
- How the model was chosen (`CLI`, `config`, `interactive`, or `default`) and the config file path used, or "none"
- The model's trained maximum context (C2), or `n/a` if it cannot be read

## 4. Live cache test

The live test checks the server directly. It does not depend on any frontend.

1. Build a fixed prefix of about 4,000 tokens from a deterministic text block shipped with the tool. The same bytes are used on every run.
2. Request 1: prefix plus question A. Record time to first token (TTFT), total time, and the prompt token count.
3. Request 2: the same prefix plus question B. Record the same values and the cached-token count.
4. Turns 3 and 4 (for C5): extend the conversation with the previous answer and a new question, keeping thinking enabled. Record cached-token counts.
5. Read the cache counter from the response in this order of preference: `usage.prompt_tokens_details.cached_tokens` (OpenAI-compatible responses), `timings.cache_n` (llama.cpp), then Ollama's `prompt_eval_cached_count` (reported by current Ollama versions alongside the full `prompt_eval_count`), and only if that is missing, `prompt_eval_count` compared with request 1's prompt length (older Ollama, where a small number means most of the prompt came from the cache). For Ollama, send requests to `/api/chat` with `keep_alive` (for example `10m`) so the model and its cache stay loaded between requests, and `think: true` when `/api/show` lists the `thinking` capability. If none of these is present, the result is inferred from TTFT and marked "server-side counter not reported".
6. Use `max_tokens` of 64 so the test runs quickly.

Decision details (as built in the macOS tool, and required for all three):

- C4 uses request 2's prompt token count as the size of the shared prefix (the differing question adds about 20 tokens). 80% or more cached is PASS, 1% to 79% is WARN, 0 is FAIL.
- C5 compares the cached-token counts of turns 2, 3 and 4: a drop from 2 to 3 or from 3 to 4 counts as one drop. One drop is WARN; drops on both is FAIL. If no turn produced reasoning output, C5 is SKIP.
- C2 with the live test skipped and no model loaded is SKIP.
- The live test leaves the model loaded for the `keep_alive` period; the 2-minute budget is measured from the end of request 1, so model load time is excluded.

Timing is reported for information only. Pass and fail decisions use cache counters, not timing, because timing varies with load.

## 5. Command line interface

```
local-llm-checkup.sh [options]

  -s, --server <ollama|lmstudio|llamacpp>   Server to test (default: auto-detect)
  -u, --url <url>                           Override endpoint
  -m, --model <name>                        Model to test (validated against installed models;
                                            default: first loaded model)
  -i, --interactive                         Choose server and model from a menu (automatic on a
                                            terminal when no model is given by CLI or config)
      --list-models                         List installed models for the server and exit
  -c, --config <file>                       Config file (see 5.2)
  -l, --log <path>                          Server log file for C3 and C4
      --session-log <path>                  Agent session log for C4 (optional)
      --skip-live                           Run static checks only
  -o, --output <dir>                        Report directory (default: ./reports)
      --no-color                            Disable colours
      --no-open                             Do not open the HTML report at the end
  -h, --help                                Show help
      --version                             Show version
```

`--url` requires `--server` so the API type is known (exit 3 otherwise).

Default log locations checked when `--log` is not given:

| Server | Default log location (macOS) |
|---|---|
| Ollama | `~/.ollama/logs/server.log` |
| LM Studio | `~/.lmstudio/server-logs/` (most recent file) |
| llama.cpp | none; the tool asks for `--log` if the live test needs it |

### 5.1 Model listing and selection

- `--list-models` lists the installed models of the selected or auto-detected server, with sizes where reported (Ollama `GET /api/tags`; LM Studio and llama.cpp `GET /v1/models`), then exits 0. It exits 3 if no server responds. Embedding models (for example `nomic-embed-text`, `all-minilm`, names containing `embed`, the Ollama `bert` family, or an LM Studio `type` of embeddings) are marked as not selectable.
- `--model` is checked against the installed list. An unknown model prints an error plus the installed list and exits 3. For Ollama the name is accepted with or without `:latest`. An embedding model is rejected with exit 3.
- Interactive picker: `--interactive` shows a numbered menu of installed non-embedding models (with sizes) and reads a number. Empty input chooses 1; out-of-range or non-numeric input re-prompts; end of input exits 3. If more than one server responded and none was configured, a server menu is shown first. The menu is drawn on the terminal, not standard output, so it never appears in piped output.
- The picker also runs automatically when stdin and stdout are terminals (`[ -t 0 ] && [ -t 1 ]`) and no model was given on the command line or in the config file. The tool never prompts when not attached to a terminal (scripts, pipes, CI); it falls back to the default model so scripted runs behave as before.
- Default model: the first loaded model (Ollama `GET /api/ps`), otherwise the first installed non-embedding model.
- The report records how the model was chosen: `CLI`, `config`, `interactive`, or `default`.

### 5.2 Config file

- Read from `--config <path>` if given (unreadable file: exit 3), otherwise the first that exists of `local-llm-checkup.conf` next to the script, then `~/.config/local-llm-checkup/config`.
- Format: plain `KEY=value` lines. Blank lines and lines starting with `#` are ignored. Values may be wrapped in matching single or double quotes; otherwise a trailing ` # comment` is removed.
- Keys: `SERVER`, `URL`, `MODEL`, `LOG`, `SESSION_LOG`, `OUTPUT`, `SKIP_LIVE`, `NO_COLOR`, `OPEN_REPORT`. Booleans accept 0/1, true/false, yes/no, on/off. Key names are case-insensitive.
- The file is parsed as text. It is never sourced, evaluated, or dot-included. Unknown keys and malformed lines produce a warning on stderr and are ignored.
- Precedence: command line, then config file, then auto-detect and built-in defaults.
- Ship `local-llm-checkup.conf.example` with every key commented out, and git-ignore the real config file.

## 6. Terminal output

- Colours use ANSI escape codes: green for PASS, yellow for WARN, red for FAIL, dim grey for SKIP, cyan for headings and progress.
- Colours are turned off when `--no-color` is set, when the `NO_COLOR` environment variable is set, or when stdout is not a terminal.
- Each check prints one line as it runs: `[C1] Claude Code attribution header ........ PASS`
- A progress line is shown during the live test.
- The final summary prints the overall score in colour and the paths to the markdown and HTML reports.
- At the end of a run, the tool opens the HTML report in the default browser with `open <report>.html`. It does this only when standard output is an interactive terminal and the `CI` environment variable is not set, and never in pipes, scripts or CI. `--no-open` or `OPEN_REPORT=0` turns it off; `OPEN_REPORT=1` cannot force opening outside a terminal. If the HTML report was not written, nothing is opened. A failure to open prints an error to stderr and does not change the exit code.

## 7. Report

The report is written to `<output>/llm-checkup-macos-<YYYYMMDD-HHMMSS>.md`.

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
| C1 | Claude Code attribution header | PASS | 1.0 | Claude Code 2.1.188 |
| C2 | Ollama context window | FAIL | 0.0 | Context 32000, minimum 64000 |
| C3 | Hybrid model and prompt reprocessing | WARN | 0.5 | Hybrid model, no reprocessing message yet |
| C4 | Frontend cache tokens | PASS | 1.0 | Cached 3,980 of 4,012 prefix tokens |
| C5 | Thinking tokens preserved | PASS | 1.0 | Cache grew on turns 2, 3, 4 |
| | **Overall** | | **60%** | 4 items scored, 0 skipped |
```

### 7.3 Recommendations

Each recommendation has four parts: what was found, why it matters, the steps to fix it on macOS, and how to verify the fix (re-run the tool). Steps use Terminal commands and macOS-specific paths.

Fix guidance for each item:

**C1 (Claude Code):**
- Run `claude update`, or reinstall using the official installer, then open a new Terminal window.
- If an update is not possible, run `echo 'export CLAUDE_CODE_ATTRIBUTION_HEADER=0' >> ~/.zshrc`, then open a new Terminal window.
- If Claude Code is started from an app or launcher rather than Terminal, run `launchctl setenv CLAUDE_CODE_ATTRIBUTION_HEADER 0`, then restart the app.

**C2 (Ollama context):**
- If the loaded context equals the model's trained maximum and that maximum is below 64,000, the detail reads `Context 32,768 = model maximum 32,768; setting cannot raise it` and these steps replace the ones below:
  - This model was trained with a maximum context of N tokens, and Ollama never loads it with more. Raising `OLLAMA_CONTEXT_LENGTH` will not change it.
  - Use a model with a larger trained context window (64,000 tokens or more) for agent sessions. Check a model's limit with `ollama show <model>` (the "context length" line) before choosing it.
  - Re-run the tool with that model (`--model <model>` or the interactive picker) and confirm C2 shows PASS.
- Otherwise (loaded context below the maximum, or maximum unknown), use these steps. When the maximum is known, show it in the detail (for example `Context 32,768, minimum 64,000; model maximum 131,072`) and in the first step.
- Run `ollama ps` and note the CONTEXT column.
- Set the context length to at least 64000. Run `launchctl setenv OLLAMA_CONTEXT_LENGTH 65536`, then quit Ollama from the menu bar and reopen it. For `ollama serve` started from Terminal, use `OLLAMA_CONTEXT_LENGTH=65536 ollama serve` instead.
- Run `ollama ps` again to confirm the new value. Ollama must reload the model before the change applies.
- Higher context uses more unified memory. On a 48 GB Mac, check Activity Monitor for memory pressure after the change.

**C3 (Hybrid model and reprocessing):**
- Open `~/.ollama/logs/server.log` (or the LM Studio or llama.cpp log) and search for `full prompt reprocessing`. Use `grep -i "full prompt reprocessing" <log>`.
- For llama.cpp, restart `llama-server` with `-v 4` (or `--verbosity 4`) to see the cache-related log lines.
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

- Written next to the markdown report: `llm-checkup-macos-<timestamp>.html`. Both paths are printed in the final summary.
- Generated with a small converter written in `awk` (no pandoc, Python or Homebrew packages). It converts exactly what the report uses: headings, paragraphs, bold, inline code, fenced code blocks, bullet lists, tables (including `\|` escaped inside cells) and links.
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
| 3 | Tool error: missing dependency, bad arguments, unreadable config file, unknown or embedding model, no server for `--list-models`, end of input at the interactive picker, or a server named with `--server` that is unreachable while `--skip-live` is not set |

## 9. Dependencies

Required: `bash` 3.2 or later, `curl`, `jq`, `sed`, `awk`, `grep`, `date`, `sysctl`, `sw_vers`.

If `jq` is missing, the tool prints the install command (`brew install jq`) and exits with code 3. It never installs packages itself.

## 10. Acceptance criteria

1. Runs on macOS 14 and later on Apple Silicon without extra installs beyond `jq`.
2. Produces a valid markdown report containing the results table, score, and a recommendation for every non-PASS item.
3. Terminal output is coloured, and colour can be turned off as specified in section 6.
4. Makes no changes to any configuration, environment variable, or application setting.
5. Live test uses identical prefix bytes on every run.
6. Exit codes match section 8.
7. Each recommendation names the macOS-specific command or path required.
8. Test completes within 2 minutes on a model that loads within 60 seconds, excluding the time to load the model.
9. `--list-models`, `--model` validation, the interactive picker and the config file behave as in section 5.1 and 5.2, and the tool never prompts without a terminal.
10. An HTML copy of the report is written as in section 7.4, and failure to write it does not change the markdown report or the exit code.
11. The HTML report opens at the end only in an interactive terminal outside CI, and `--no-open` / `OPEN_REPORT=0` disable it.
