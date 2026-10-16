# Local LLM Checkup for macOS

`local-llm-checkup.sh` checks whether your local LLM server on an Apple Silicon Mac is
hitting its KV prefix cache, the most common reason local AI agents feel slow. It inspects
the settings that break the cache, runs a short live test against the server, and writes a
markdown report with a score and macOS fix steps for anything that did not pass.

It **never changes** configuration, environment variables or application settings. It only
reads them and sends test requests. Implements
[`documentation/SPECIFICATION-MacOS.md`](../documentation/SPECIFICATION-MacOS.md) v1.0.0.

## Requirements

- macOS 14 (Sonoma) or later on Apple Silicon
- `bash` 3.2+ (the macOS default `/bin/bash` works), `curl`, `sed`, `awk`, `grep`, `date`, `sysctl`, `sw_vers`
- `jq` (`brew install jq` if missing; the tool exits with code 3 and prints that command)
- One local server: Ollama (`:11434`), LM Studio (`:1234`) or llama.cpp `llama-server` (`:8080`)

## Files

| File | Purpose |
|---|---|
| `local-llm-checkup.sh` | The tool |
| `hybrid-models.txt` | Model-name patterns for hybrid / SSM / recurrent models (check C3). One `grep -E` pattern per line, `#` comments, uncertain entries marked |
| `local-llm-checkup.conf.example` | Example config file (copy to `local-llm-checkup.conf`) |
| `prefix.txt` | Fixed ~3,800-token text block used as the shared prompt prefix. Do not edit: every run must send identical bytes |
| `reports/` | Default report directory (git-ignored) |

## Usage

```
./local-llm-checkup.sh [options]

  -s, --server <ollama|lmstudio|llamacpp>   Server to test (default: auto-detect)
  -u, --url <url>                           Override endpoint (requires --server)
  -m, --model <name>                        Model to test (validated against installed models;
                                            default: first loaded model)
  -i, --interactive                         Choose server and model from a menu (automatic on a
                                            terminal when no model is given by CLI or config)
      --list-models                         List installed models for the server and exit
  -c, --config <file>                       Config file (default: ./local-llm-checkup.conf next to
                                            the script, then ~/.config/local-llm-checkup/config)
  -l, --log <path>                          Server log file for C3 and C4
      --session-log <path>                  Agent session log for C4 (optional)
      --skip-live                           Run static checks only
  -o, --output <dir>                        Report directory (default: ./reports)
      --no-color                            Disable colours
  -h, --help                                Show help
      --version                             Show version
```

Examples:

```bash
./local-llm-checkup.sh                              # auto-detect server, first loaded model
./local-llm-checkup.sh --list-models                # show installed models (embedding models marked)
./local-llm-checkup.sh -i                           # pick server/model from a numbered menu
./local-llm-checkup.sh -m qwen2.5:3b                # test a specific Ollama model
./local-llm-checkup.sh -c ~/checkup.conf            # use a config file
./local-llm-checkup.sh -m qwen3.5:4b                # thinking model: exercises C5
./local-llm-checkup.sh --skip-live                  # static checks only, no requests sent
./local-llm-checkup.sh -s llamacpp -l ~/llama.log   # llama.cpp started with -v 4, logging to a file
./local-llm-checkup.sh -s lmstudio -o ~/Desktop     # LM Studio, report on the Desktop
NO_COLOR=1 ./local-llm-checkup.sh                   # plain output
```

## Choosing the model

- `--list-models` prints the installed models of the selected or auto-detected server
  (Ollama `/api/tags` with size; LM Studio and llama.cpp `/v1/models`) and exits 0, or 3 if
  no server responds. Embedding models are marked and cannot be selected.
- `-m <name>` is checked against that list. An unknown model prints the installed models and
  exits 3; Ollama accepts the name with or without `:latest`. Embedding models are rejected (exit 3).
- With no model from the CLI or config, and both stdin and stdout on a terminal, a numbered menu
  of installed chat models appears (plus a server menu when several servers respond and none is
  configured). `-i` forces the menu. Without a terminal it never prompts: it uses the defaults below
  so scripts and CI behave as before.
- The report header records how the model was chosen: `CLI`, `config`, `interactive` or `default`.

Example menu (Ollama on an M2):

```
Installed models on Ollama (embedding models hidden):
   1) qwen3.5:4b                                  3.2 GB
   2) qwen2.5:3b                                  1.8 GB
   3) granite3-moe:3b                             1.9 GB
   4) gemma3:4b                                   3.1 GB
   5) nemotron-3-nano:4b                          2.6 GB
Choose 1-5 [1]: 2
```

## Config file

Read from `-c <file>`, else `local-llm-checkup.conf` next to the script, else
`~/.config/local-llm-checkup/config`. Plain `KEY=value` lines; `#` comments; optional quotes.
Keys: `SERVER`, `URL`, `MODEL`, `LOG`, `SESSION_LOG`, `OUTPUT`, `SKIP_LIVE` (0/1), `NO_COLOR` (0/1).
The file is parsed as text (never sourced or executed); unknown keys and malformed lines are
ignored with a warning. Precedence: command line > config file > auto-detect / defaults.
See `local-llm-checkup.conf.example`.

## Defaults

Auto-detection probes Ollama, then LM Studio, then llama.cpp and uses the first that answers.
Without `--model`, Ollama uses the first loaded model (or the first installed non-embedding
model, which the live test then loads); LM Studio and llama.cpp use the first entry of `/v1/models`.

Default server logs: Ollama `~/.ollama/logs/server.log`; LM Studio the newest file in
`~/.lmstudio/server-logs/`; llama.cpp has none, so pass `--log`.

## Checks

| ID | Item | PASS | WARN | FAIL |
|---|---|---|---|---|
| C1 | Claude Code attribution header | `claude` ≥ 2.1.181 or `CLAUDE_CODE_ATTRIBUTION_HEADER=0` | version unparseable | older and variable not `0` |
| C2 | Ollama context window (`ollama ps` CONTEXT) | ≥ 64,000 | 32,000–63,999 | < 32,000 |
| C3 | Hybrid model / `full prompt reprocessing` in log | not hybrid, or no message | hybrid, no message yet | message logged during this run |
| C4 | Cache tokens on request 2 | cached ≥ 80% of prompt | no counter (timing only), or 1–79% | 0 cached |
| C5 | Thinking preserved (turns 2→3→4) | cached never drops | drops once | drops on two consecutive turns |

SKIP (not applicable) and ERROR (could not run) are excluded from the score. The overall score
is the mean of PASS=1.0, WARN=0.5, FAIL=0.0.

### Live test

Four streamed chat requests with `max_tokens` 64:
1. `prefix.txt` (system message) + question A (includes model load; not counted in the 2-minute budget)
2. same prefix + question B: cached tokens here decide C4
3. turn 2 + its answer (including reasoning) + question C
4. turn 3 + its answer + question D

Cache counters are read in this order: `usage.prompt_tokens_details.cached_tokens`
(OpenAI-compatible), `timings.cache_n` (llama.cpp), then Ollama's `prompt_eval_cached_count`
(Ollama 0.40 reports it) or, on older Ollama, `prompt_eval_count` compared with request 1's
prompt length. Ollama requests use `/api/chat` with `keep_alive` 10m, and `think: true` when
`/api/show` lists the `thinking` capability. Timing is shown for information only.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All scored items PASS |
| 1 | At least one WARN, no FAIL |
| 2 | At least one FAIL |
| 3 | Tool error: missing dependency, bad arguments, unreadable config file, unknown or embedding model, no server for `--list-models`, menu input ended, or a server chosen with `--server` that is unreachable without `--skip-live` |

## Report

Written to `<output>/llm-checkup-macos-YYYYMMDD-HHMMSS.md` with: title and timestamp,
environment, summary counts, results table, live test details (per-turn TTFT, total time,
prompt and cached tokens, reasoning size), a recommendation for every non-PASS item
(found / why / macOS fix / verify), and notes and limitations.

## Limitations

- C3 only counts `full prompt reprocessing` lines written during the run. Ollama and
  LM Studio may never log that phrase; llama.cpp logs it at `-v 4`.
- `hybrid-models.txt` is name-based; renamed or new models may be missed.
- With auto-detect and no server answering, the live checks are SKIP rather than exit 3
  (spec 2.1); an explicitly chosen server that is down is exit 3 (spec 8).
- C4 uses request 2's prompt token count as the shared prefix size (the question adds ~20 tokens).
- The live test leaves the model loaded for 10 minutes (Ollama `keep_alive`).
- LM Studio and llama.cpp paths are implemented to the OpenAI-compatible API but were not
  exercised against a live server during development (only Ollama 0.40.0 was).
