# LocalAIChecker

**Find out why your local AI feels slow, and what to change to fix it.**

LocalAIChecker is a free health check for AI models running on your own computer through
Ollama, LM Studio or llama.cpp. It looks at your setup, runs a short test conversation with
your model, and gives you a scored report in plain language with clear steps to fix whatever
is holding it back.

It runs on **macOS**, **Windows** and **Linux**.

---

## Why it exists

Local AI assistants and coding agents keep sending the same long block of instructions with
every message. A well-set-up server remembers that block (this is called *prompt caching*) and
only processes what is new, so replies start quickly. When a setting quietly breaks that
memory, the server re-reads everything on every turn and replies can take many times longer.
The model still works, so nothing tells you that anything is wrong.

LocalAIChecker finds these hidden problems for you.

## What it checks

| Check | What it asks |
|---|---|
| Agent settings | Is your AI coding tool set up so that it doesn't break the cache? |
| Context size | Does the model have enough working memory for agent work? |
| Model type | Is this a kind of model that can't reuse its memory well? |
| Cache in action | When the same text is sent twice, does the server actually reuse it? |
| Thinking models | Does the cache survive a multi-turn conversation with a reasoning model? |

Each check comes out as **PASS**, **WARN** or **FAIL**, and together they give one overall
score. For anything that didn't pass, the report explains what it found, why it matters, how to
fix it on your operating system, and how to confirm the fix worked.

## Safe by design

- **It changes nothing on your computer.** It only reads your settings and sends a few test
  messages to your local model.
- **Your data stays on your computer.** Everything runs locally and nothing is uploaded.
- **The whole check takes about two minutes**, plus the time the model takes to load.

## The report

Every run saves two copies of the report: a Markdown file for keeping notes, and a colour-coded
web page that opens in your browser when the run finishes. Reports are kept in a `reports`
folder next to the tool.

## Choosing a model

If you have several models installed, the tool can list them and let you pick one from a menu.
You can also save your usual choices in a small settings file, so you don't have to pick each
time.

---

## Usage: macOS

**You need** an Apple Silicon Mac running macOS 14 (Sonoma) or later, plus `jq`
(`brew install jq`).

```bash
cd MacOS
chmod +x local-llm-checkup.sh
./local-llm-checkup.sh                     # auto-detect the server; pick a model from a menu
./local-llm-checkup.sh --list-models       # list installed models
./local-llm-checkup.sh -m qwen2.5:3b       # test one model
./local-llm-checkup.sh --skip-live         # settings checks only, no test messages
./local-llm-checkup.sh --no-open           # don't open the HTML report
./local-llm-checkup.sh --help              # every option
```

Settings file: copy `local-llm-checkup.conf.example` to `local-llm-checkup.conf` in the same
folder, or to `~/.config/local-llm-checkup/config`.

Full details are in [MacOS/README.md](MacOS/README.md).

## Usage: Windows

**You need** Windows 10 21H2+ or Windows 11, with Windows PowerShell 5.1 or PowerShell 7+.
Nothing else needs installing.

```powershell
cd Windows
.\Invoke-LocalLLMCheckup.ps1                          # auto-detect; menu if no model is set
.\Invoke-LocalLLMCheckup.ps1 -ListModels              # list installed models
.\Invoke-LocalLLMCheckup.ps1 -Model qwen2.5:3b        # test one model
.\Invoke-LocalLLMCheckup.ps1 -SkipLive                # settings checks only
.\Invoke-LocalLLMCheckup.ps1 -NoOpen                  # don't open the HTML report
.\Invoke-LocalLLMCheckup.ps1 -Help                    # every option
```

The script isn't signed. If your execution policy blocks it, run it once like this (the tool
never changes the policy):

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-LocalLLMCheckup.ps1
```

Settings file: copy `local-llm-checkup.conf.example` to `local-llm-checkup.conf` in the same
folder, or to `%APPDATA%\local-llm-checkup\config`.

Full details are in [Windows/README.md](Windows/README.md).

## Usage: Linux

**You need** Debian or Ubuntu (other distributions will probably work), `bash`, `curl` and `jq`
(`sudo apt install jq curl`).

```bash
cd Linux
chmod +x local-llm-checkup.sh
./local-llm-checkup.sh                     # auto-detect the server; pick a model from a menu
./local-llm-checkup.sh --list-models       # list installed models
./local-llm-checkup.sh -m qwen2.5-coder:7b # test one model
./local-llm-checkup.sh --skip-live         # settings checks only
./local-llm-checkup.sh --help              # every option
```

For Ollama installed as a system service, the tool reads its log from the system journal. If
that is not allowed, add yourself to the `systemd-journal` group or pass `--log <file>`. The
report opens in your browser only on a desktop session, not over SSH.

Settings file: copy `local-llm-checkup.conf.example` to `local-llm-checkup.conf` in the same
folder, or to `~/.config/local-llm-checkup/config`.

Full details are in [Linux/README.md](Linux/README.md).

---

## What the result means

| Result | Meaning |
|---|---|
| All PASS | Your setup is healthy. |
| Some WARN | It works, but something could be faster. The report says what. |
| Any FAIL | Something is slowing your AI down. Follow the fix steps in the report. |

## Supported servers

- [Ollama](https://ollama.com)
- [LM Studio](https://lmstudio.ai)
- [llama.cpp](https://github.com/ggml-org/llama.cpp) (`llama-server`)

Ollama has been tested on macOS and Linux. LM Studio, llama.cpp and the Windows tool are built
to the same specification but have not yet been tested on real systems.

## Project documents

- [Shared plan](documentation/PLAN.md)
- [macOS specification](documentation/SPECIFICATION-MacOS.md)
- [Windows specification](documentation/SPECIFICATION-Windows.md)
- [Linux specification](documentation/SPECIFICATION-Linux.md)
