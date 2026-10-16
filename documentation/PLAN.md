# YOUR ROLE
You are an expert AI engineer working in Large Language Model training and engineering. You help code and build the harnesses built around frontier AI models like Claude Code, Codex and DeepSeek Harness.

# CONTEXT
Local AI on a Mac feels slow for a reason the tokens-per-second counter never shows: your local LLM re-reads the whole prompt every turn. An M5 Max MacBook Pro with 128GB of unified memory spent 8 hours making 15 edits with a coding agent, and the chip was never the problem.
Every "why is local AI slow on my Mac" video lands on memory bandwidth, and that part is real. A Mac mini M6 moves 170 GB/s, an M5 Max moves 614 GB/s, and the M5's neural accelerators made prompt reading about 3.6x faster than the M4 Max on llama.cpp's own benchmarks. But bandwidth only sets how fast the model writes. Before the first word, it has to read everything you sent it, and in an agent loop that reading is most of the wait. One M1 Max showed 57 tokens per second in LM Studio while the real speed at 8,500 tokens of context was 3.
The fix is the KV cache, and specifically prefix caching. On the same M5 Pro, in the same session, with the same Qwen3.8-27B model, the first word took 6.1 seconds when the start of the prompt matched the cache and 268 seconds when it didn't. That's 44x, which is a bigger gap than any Apple Silicon upgrade can close.
What breaks the cache: the Claude Code attribution header (fixed in v2.1.181, so update first), Ollama's default context window (32K on a 48GB Mac, smaller than Claude Code's ~33,000-token first request), hybrid models like Qwen3.8-27B that can't rewind past a checkpoint, frontends that send zero cached tokens, and tools that strip thinking tokens between turns. Most guides to speeding up a local LLM, whether that's switching Ollama to MLX, running a mixture of experts model or adding speculative decoding, make the writing faster. None of them stop an agent from re-reading its prompt from scratch.
The chip still matters for cold reads. A 32,000-token first read on a 27B model takes minutes on an M1 Max and about 40 seconds on an M5 Max. So fix the cache first, then decide whether you need new local AI hardware.

# WHAT'S COVERED IN THE VIDEO
Memory bandwidth explained: why it sets writing speed and not reading speed
Prefill vs decode, and why the LM Studio and Ollama counters only show decode
The same M5 Pro at 6.1 seconds and 268 seconds, and what changed between them
The Claude Code header bug and the CLAUDE_CODE_ATTRIBUTION_HEADER fix
Ollama's default context window vs Claude Code's first request (check it with `ollama ps`)
Why hybrid models lose the KV cache, and the llama.cpp log line that only shows at verbosity 4
OpenClaw vs Hermes on the same server: zero cached tokens vs a working cache
Where the M5 Pro and M5 Max really do earn their price
A five-step checklist to run before you buy a faster Mac

# THE WAY TO FIX THIS
The checklist:
- Update Claude Code. An attribution header bug broke the prompt cache, and it’s fixed in v2.1.181. Set CLAUDE_CODE_ATTRIBUTION_HEADER as the fix describes.
- Check Ollama’s context window. The default is 32K on a 48GB Mac, which is smaller than Claude Code’s first request (about 33,000 tokens). Run ollama ps to see what’s actually loaded.
- Check whether the model is hybrid. Hybrid models such as Qwen3.8-27B can’t rewind past a checkpoint, so they lose the cache. The llama.cpp log line that shows this appears at verbosity 4.
- Check that your frontend caches tokens. Some frontends send zero cached tokens. The video compares OpenClaw (zero cached tokens) with Hermes (caching works).
- Check whether your tools strip thinking tokens between turns. Stripping them can break the cache.

The main point is to look at prompt processing (prefill) and cache hits, not the tokens-per-second counter, which only measures how fast the model writes. A cache hit took 6.1 seconds in the video’s test, and a cache miss took 268 seconds.


# VIDEO TRANSCRIPT

00:00:00.080
So, I want you to imagine this with me
00:00:01.680
for a second. You just dropped three
00:00:04.400
maybe $4,000 on a brand new MacBook Pro
00:00:07.520
with an M5 Max chip and 128 GB of
00:00:10.800
unified memory. And it's fast where it
00:00:13.120
opens Xcode instantly, renders video
00:00:15.839
without breaking a sweat, and runs
00:00:17.680
circles around anything you owned
00:00:19.439
before. And then you try to run a local
00:00:21.279
AI agent on it. and you wait and you
00:00:23.920
wait some more and eventually you get
00:00:26.080
up, make a coffee, come back and it's
00:00:29.119
still thinking. Now, this is not a
00:00:31.199
hypothetical because it actually
00:00:32.960
happened to a developer on Reddit on the
00:00:35.680
fastest laptop Apple makes. He spent 8
00:00:38.640
hours running a coding agent to make
00:00:40.559
about 15 edits to one HTML file. That
00:00:43.600
works out to half an hour per edit on an
00:00:46.000
M5 Max with 128 gigs of RAM. And the
00:00:49.680
part that messed me up when I read it is
00:00:51.280
that he said the answers were excellent.
00:00:53.360
The writing speed looked fine on screen
00:00:55.680
and memory was totally okay. But then he
00:00:58.320
opened the logs and there was one line
00:01:00.559
just repeating over and over again which
00:01:03.440
said forcing full prompt reprocessing
00:01:05.920
due to lack of cache data. And that was
00:01:08.159
the moment I realized that everything I
00:01:10.479
thought I knew about why local AI is
00:01:12.640
slow on a Mac was wrong because we've
00:01:15.200
all been looking at the wrong thing.
00:01:17.040
Now, before we get into what's actually
00:01:18.960
going on, I want to be fair to the chip
00:01:21.119
argument. If you search YouTube right
00:01:23.360
now for why is local AI slow on Mac,
00:01:26.799
every single video is going to talk
00:01:28.479
about one thing, which is memory
00:01:30.400
bandwidth. And those videos aren't
00:01:32.320
lying, they're just incomplete. The
00:01:34.560
logic behind them is sound. When a model
00:01:37.119
is writing, generating each new word, it
00:01:39.920
has to pull the entire model weights out
00:01:42.320
of memory and through the chip for every
00:01:44.720
single token. A model like Quinn 3.827B
00:01:48.799
at 4bit quantization is about 17 GB and
00:01:52.320
the Mac Mini M6 can move 170 GB per
00:01:55.840
second. So we're getting roughly 10
00:01:57.680
tokens per second there. An M5 Max
00:02:00.320
pushes 614 GB per second, which is about
00:02:03.840
3.5 times faster. So yes, more bandwidth
00:02:07.759
really does equal more words per second.
00:02:10.318
And that math is real. And the M5
00:02:12.480
generation added another actual win
00:02:14.560
since Apple put matrix acceleration
00:02:16.720
units inside every single GPU core. And
00:02:19.920
reading a prompt got about 3.6 times
00:02:22.480
faster from the M4 Max to the M5 Max on
00:02:25.599
Llama CPP's own benchmarks. So the
00:02:28.160
standard advice writes itself because if
00:02:30.160
your Mac is slow, why wouldn't you just
00:02:32.000
buy more bandwidth and buy an M5? But
00:02:34.400
the developer with the 8-hour session
00:02:36.640
already had both with 614 GB per second
00:02:40.400
and accelerators in every core. And he
00:02:43.440
still spent a working day getting 15
00:02:45.440
edits done. So clearly something else is
00:02:47.920
going on here. When I first started
00:02:49.760
digging into this, I genuinely thought I
00:02:52.080
was missing something obvious. Like
00:02:54.080
surely it's just the model size and the
00:02:56.239
fixes to run a smaller model, right? But
00:02:58.879
the same issue hits people running
00:03:00.480
midsize models on perfectly capable
00:03:02.720
hardware. Which means the problem isn't
00:03:04.879
what we're running, it's how the tool is
00:03:07.120
reading it. Now, there's something
00:03:09.599
almost nobody tells you when you set up
00:03:11.440
local AI. And I wish someone had told me
00:03:13.599
early on because it would have saved me
00:03:15.519
a lot of frustration. Your Mac is
00:03:17.519
actually doing two completely different
00:03:19.599
jobs when it runs an AI model. And the
00:03:21.920
counter we're all watching in LM Studio
00:03:23.840
or OAMA only measures one of them. That
00:03:26.480
number, your tokens per second, is
00:03:28.959
showing how fast the model writes, or in
00:03:31.280
other words, how fast it generates new
00:03:33.200
words. But before the first word ever
00:03:35.440
appears, the model has to read
00:03:37.519
everything you sent it. So the system
00:03:39.519
prompt, the files you attached, and the
00:03:42.000
entire conversation history all go
00:03:43.840
through first. And that reading phase
00:03:46.159
has its own speed and its own
00:03:47.920
bottleneck. And it can be dramatically
00:03:50.319
slower than the writing phase. In a
00:03:52.400
normal chat window, we type a couple
00:03:54.480
hundred words and the reading takes a
00:03:56.480
fraction of a second, which nobody would
00:03:58.959
ever notice. So, it's easy to assume
00:04:00.879
coding agents work the same way, and
00:04:03.200
they don't. Not even close. The example
00:04:06.080
that really changed how I think about
00:04:07.920
this came from a developer who measured
00:04:09.680
it in March on an M1 Max. LM Studio was
00:04:12.959
showing a perfectly respectable 57
00:04:15.040
tokens per second, but when they timed
00:04:17.440
things from pressing enter to the actual
00:04:19.759
first word with 8,500 tokens of
00:04:22.639
conversation context loaded in, the real
00:04:25.520
speed was three tokens per second. The
00:04:28.400
reading was hitting 94% of the wait
00:04:30.960
time, which made the real speed 19 times
00:04:34.000
slower than the counter said. Engineers
00:04:36.160
call these two phases prefill and
00:04:38.240
decode, where prefill is reading and
00:04:40.720
decode is writing. And almost every
00:04:42.960
benchmark we've ever watched on YouTube
00:04:44.800
is measuring decode, while almost every
00:04:47.280
agent workflow we actually run is
00:04:49.520
dominated by prefill. And I think this
00:04:51.600
is one of the most important things to
00:04:53.120
understand about local AI on a Mac
00:04:55.440
because it completely reframes every
00:04:58.000
purchase decision and every
00:04:59.680
troubleshooting step. And we can have
00:05:01.759
blazing fast decode with absolutely
00:05:04.160
brutal prefill times while the counter
00:05:06.080
on the screen never tells us. Now we're
00:05:08.320
getting to the part that genuinely made
00:05:10.160
my jaw drop. Because we've established
00:05:11.840
that reading is slow, but what makes it
00:05:13.919
catastrophically slow instead of just
00:05:15.759
slow is the part nobody puts on a chart.
00:05:18.639
A server, whether it's running locally
00:05:20.560
or in the cloud, can remember what it
00:05:22.800
already read. So if the next request
00:05:24.960
starts with the same text as the last
00:05:26.800
one, it doesn't reread all of that and
00:05:29.120
skip straight to the new stuff at the
00:05:30.639
end. This is called prefix caching. And
00:05:33.440
on a Mac, it is the difference between
00:05:35.280
usable and completely broken. And when
00:05:37.600
we look at a real session, a developer
00:05:39.759
in September posted logs from an M5 Pro
00:05:42.639
with 64 GB running Quinn 3.827B.
00:05:46.800
At one point, the context was 158,000
00:05:49.919
tokens long, but 157,600
00:05:53.360
of them were already in cash and only
00:05:55.440
400 were new. So, the first word
00:05:57.759
appeared in 6.1 seconds. A few turns
00:06:00.479
later, the context had grown to 188,000
00:06:03.440
tokens, but the cash only matched
00:06:06.319
147,000 of them, and that left the
00:06:08.800
server rereading about 41,000 tokens
00:06:11.600
from scratch, and the first word took
00:06:14.080
268 seconds. That's the same Mac, the
00:06:17.360
same model, the same session, and the
00:06:19.680
same conversation. And it took 44 times
00:06:22.800
longer. And the only difference was
00:06:24.639
whether the beginning of the prompt
00:06:26.319
still matched what the server had
00:06:27.919
already seen. And that's the number that
00:06:30.160
reframes everything. Going from an M5
00:06:32.400
Pro to an M5 Max more than doubled your
00:06:34.720
memory bandwidth, which is a real gain.
00:06:37.280
But breaking the cash cost you 44 times.
00:06:40.319
And there is no chip upgrade Apple
00:06:42.160
makes, not the Max and not the Ultra,
00:06:44.639
that closes a 44x gap. So, the next
00:06:47.199
thing I wanted to know was what breaks
00:06:49.039
the cash? And this is where I went down
00:06:51.199
a rabbit hole for a while because the
00:06:53.120
answers turned out to be surprisingly
00:06:54.800
mundane. It's not some fundamental
00:06:57.280
limitation of the hardware. It's
00:06:59.199
software decisions, tool choices, and
00:07:02.160
settings, which is stuff we can actually
00:07:04.080
fix. So, let's walk through the ways
00:07:06.240
that cash is probably dying silently on
00:07:08.639
you right now because some of these are
00:07:10.560
genuinely embarrassing once you know
00:07:12.240
about them. The first one is almost
00:07:13.919
legendary at this point. From at least
00:07:16.000
March until June of this year, Clot Code
00:07:18.639
was putting a tiny block of text at the
00:07:20.960
very top of its system prompt, and that
00:07:23.280
block contained a token that changed on
00:07:25.440
every single request. Entropic's own
00:07:28.000
servers knew to strip that block out
00:07:29.680
before caching. But if we point cloud
00:07:32.000
code at a local server, the local server
00:07:34.479
doesn't know that and it sees a change
00:07:36.720
token at the very top of the prompt,
00:07:39.039
which means nothing below it matches and
00:07:40.960
the entire cache is invalid every single
00:07:43.599
turn. Someone found this in March and
00:07:46.000
posted a fix which was setting one
00:07:48.319
environment variable to zero. And that
00:07:50.560
post got 46,000 views and spread across
00:07:53.759
four languages. An Unsllo setup guide
00:07:56.479
still warns about it as the number one
00:07:58.319
reason local inference feels 90% slower
00:08:01.599
than it should be. Now the fix shipped
00:08:04.080
in claude code version 2.1 in June. So
00:08:06.960
on a current version that specific issue
00:08:08.960
is gone but people were still reporting
00:08:11.360
30inut agent runs in September 3 months
00:08:14.080
after that fix shipped. So the cache was
00:08:16.400
breaking somewhere else. The second
00:08:18.240
issue is Olama's context window
00:08:20.400
defaults. And this one is almost funny
00:08:22.400
in how it happens. Ola calculates how
00:08:24.960
much memory to give the model's context
00:08:27.039
based on how much GPU memory it can see.
00:08:29.599
So below 24 gigs you get a 4,000 token
00:08:32.479
window. Between 24 and 48 gigs you get
00:08:35.360
32,000 and above 48 you get 256,000.
00:08:39.599
And on a Mac the GPU doesn't see all of
00:08:42.080
your memory because Mac OS lets it use
00:08:44.320
roughly 3/4. So a 48 GB Mac shows the
00:08:47.600
GPU about 36 GB and lands in the 32,000
00:08:51.600
token tier. Claude Code's very first
00:08:54.160
request before you've typed a single
00:08:56.240
thing is about 33,000 tokens, mostly
00:08:59.519
just tool descriptions, which means the
00:09:01.600
context window is literally full before
00:09:04.160
the agent has been asked to do anything.
00:09:05.920
What happens next is exactly what one M5
00:09:08.880
Pro owner with 48 gigs described in
00:09:11.040
September, where cloud code keeps
00:09:13.040
compacting the context over and over,
00:09:15.360
and sometimes tasks never finish.
00:09:17.760
Compaction means the tool summarizes the
00:09:20.080
conversation into a fresh, shorter
00:09:22.480
prompt. And a fresh prompt means a
00:09:24.720
completely cold read every single time.
00:09:27.440
And Olama's own Claude code
00:09:29.200
documentation says to set the context to
00:09:31.680
64,000 or more, while the default is
00:09:34.320
half that. And I don't know who's
00:09:36.000
supposed to catch that discrepancy, but
00:09:38.000
it's not the person who just wants to
00:09:39.440
write some code. The third issue is
00:09:41.600
inside the model itself, and it's a bit
00:09:43.760
more technical, but worth understanding.
00:09:45.760
Some modern long context models with
00:09:48.320
Quen 3.827B as the famous example use a
00:09:52.160
mix of layer types and about 3/4 of the
00:09:54.800
layers use a mechanism that works like a
00:09:56.720
running summary rather than storing
00:09:58.640
individual tokens. These layers are
00:10:00.800
efficient for long context but you can't
00:10:03.279
rewind the summary to an arbitrary
00:10:05.040
point. So the server saves periodic
00:10:07.279
checkpoints spaced thousands of tokens
00:10:09.440
apart. And if the new prompt diverges
00:10:12.000
from the cache at a point where no
00:10:13.600
checkpoint exists nearby, the server has
00:10:16.160
to restart from zero, which is exactly
00:10:18.399
what the log line from the 8our session
00:10:20.399
was reporting turnbyturn. The line only
00:10:22.959
shows up at log level four while the
00:10:24.959
default is level three. So most people
00:10:26.959
are running agents with this happening
00:10:28.560
constantly and have no idea. The one
00:10:30.959
that really got me shows how much of
00:10:33.040
this is outside our control when we just
00:10:35.040
pick up whatever tool looked good in a
00:10:36.800
tutorial. In May, someone tested two
00:10:39.279
agent frontends, OpenClaw and Hermes,
00:10:42.000
pointed at the exact same server running
00:10:44.240
the exact same model. And Hermes cached
00:10:46.800
fine, while OpenClaw showed zero cache
00:10:49.040
tokens. And that wasn't a few, it was
00:10:51.279
zero, because the tool itself was
00:10:53.200
structuring requests in a way that
00:10:54.800
guaranteed the cache would never be hit.
00:10:57.120
So, it's the same MAC, the same server,
00:10:59.519
and the same model with completely
00:11:01.600
different realworld performance based
00:11:03.440
purely on which front end you picked.
00:11:06.000
And there's another subtle one in
00:11:07.519
thinking tokens since a lot of these
00:11:09.440
modern models reason out loud before
00:11:11.680
they answer, writing their internal
00:11:13.600
chain of thought and then giving the
00:11:15.200
response. Some tools strip those
00:11:17.440
thinking tokens before the next turn to
00:11:19.279
keep the context cleaner, which sounds
00:11:21.279
reasonable, but it changes the
00:11:23.200
conversation history between turns and
00:11:25.120
breaks the cache from that point
00:11:26.480
forward. Quinn ships its 27B model with
00:11:29.440
thinking preserved by default for
00:11:31.120
exactly this reason and its own
00:11:32.959
documentation says it helps caching,
00:11:35.040
though plenty of tools don't respect
00:11:36.480
that. And this is why I've started being
00:11:38.240
a lot more deliberate about which server
00:11:40.480
software and front end I actually run
00:11:43.040
rather than installing whatever seemed
00:11:44.880
popular because the difference between a
00:11:46.800
cash friendly setup and a cash hostile
00:11:48.959
one can be orders of magnitude and that
00:11:51.360
swamps every other variable. Now, after
00:11:54.000
all of that, I don't want you to walk
00:11:55.600
away thinking the chip is irrelevant,
00:11:57.519
and it's not. It just isn't relevant in
00:12:00.240
the way most people think. The chip
00:12:02.320
matters for the reads we genuinely can't
00:12:04.720
skip. The very first time an agent looks
00:12:06.959
at a repository, there's no cash at all,
00:12:09.120
so we're paying the full prefill cost on
00:12:11.519
everything. In October, a content
00:12:13.680
creator put clawed code on an M5 Pro,
00:12:16.560
asked it to find bugs in a project, and
00:12:18.959
waited over 3 minutes before the agent
00:12:21.200
said its first word, which at the
00:12:23.120
typical read speeds for that setup is
00:12:25.200
55,000 to 70,000 tokens being processed
00:12:28.240
from scratch. He called local AI on a
00:12:30.800
Mac a waste of money, and 62,000 people
00:12:33.519
watch that video. But he measured turn
00:12:35.760
one, and he wasn't wrong about turn one.
00:12:38.320
And that's where the M5 earns its price.
00:12:40.880
A 32,000 token cold read on a 27B model
00:12:44.079
that used to take 5 to 11 minutes on an
00:12:46.160
M1 Max takes about 40 seconds on an M5
00:12:49.360
Max, which is a real meaningful
00:12:52.079
improvement for real work. But the
00:12:54.399
honest framing is that the cache decides
00:12:56.639
how many cold reads we have to pay for
00:12:58.800
while the chip decides what each cold
00:13:00.880
read costs. And if the setup is breaking
00:13:03.279
the cash every turn, we're paying the
00:13:05.360
cold read price every single time. And
00:13:08.320
no chip closes that gap. So fix the
00:13:10.720
reads first and then decide whether you
00:13:12.959
still want the faster chip. Now let me
00:13:15.200
give you the actual checklist which is
00:13:17.040
the stuff to check before you even think
00:13:18.800
about hardware. First update clot code
00:13:22.079
because anything older than version 2.1
00:13:25.680
181 still has the attribution header
00:13:28.160
bug. If you can't update, set the
00:13:30.560
environment variable code attribution
00:13:33.040
header to zero, which takes 5 seconds
00:13:35.600
and might be the reason every single
00:13:37.600
turn is a cold read. Second, if you use
00:13:40.399
Olama, open a terminal, run PS, and look
00:13:43.920
at the context column. And on a 48 gig
00:13:46.560
Mac, a reading of 32,000 is the problem
00:13:49.680
right there. And Lama's own
00:13:51.279
documentation says to set it to 64,000
00:13:53.920
or more, which alone can transform how
00:13:56.240
agent sessions feel. Third, turn the
00:13:59.040
server logs up. So on Lama, CPP, or LM
00:14:02.320
Studio, look for any setting about log
00:14:04.320
verbosity or debug level and bump it.
00:14:07.120
then run an agent session and search the
00:14:09.120
logs for the phrase full prompt
00:14:11.120
reprocessing. And if that's appearing
00:14:13.040
every turn, we now know exactly what's
00:14:15.360
eating the time and it has nothing to do
00:14:17.440
with the chip. Fourth, be picky about
00:14:20.000
the tool since not all frontends handle
00:14:22.160
caching the same way. So test the setup
00:14:24.560
and actually look at the cache token
00:14:26.320
counter server reports where zero cache
00:14:28.720
tokens deep in a session is a red flag
00:14:30.800
worth investigating. And fifth, which is
00:14:33.600
small but apparently meaningful, if
00:14:35.519
you're using Quen models, drop the
00:14:37.680
effort level from XUA to medium. The
00:14:40.240
highest effort setting generates five to
00:14:42.399
six times more thinking tokens and that
00:14:44.720
makes the context balloon faster and the
00:14:46.880
cash harder to maintain. That's the
00:14:49.040
checklist, and none of it costs
00:14:50.720
anything. Some of it takes 2 minutes,
00:14:53.040
and any one of these things could be the
00:14:55.279
reason a fast Mac feels slow. A faster
00:14:58.000
MAC makes every read cheaper, but a
00:15:00.399
working cache makes most of them
00:15:01.920
disappear.


# YOUR TASK
Write three tools, one for each of the main operating systems:
- MacOS 
- Windows 10/11
- Linux (Debian/Ubuntu)

Each tool should check the things noted in the checklist above and produce a report for every item checked.
The report should be in markdown format and the checlist report should be a markdown table with items and scores/results of the test.

The report should then make recommendations for every item that did not pass the checklist check with steps on how to resolve them on the specific operating system.

Use colours in the terminal/Powershell window output

## Model selection and configuration (all three tools)

Added to the macOS tool in PR #2; build the same behaviour into the Windows and Linux tools.

1. **List models:** a `--list-models` option (PowerShell: `-ListModels`) lists the installed models for the selected or auto-detected server, with sizes where the server reports them, then exits 0 (exit 3 if no server responds).
   - Ollama: `GET /api/tags`. LM Studio and llama.cpp: `GET /v1/models`.
   - Mark embedding models (for example `nomic-embed-text`, `all-minilm`, or the Ollama `bert` family) as not selectable.
2. **Interactive picker:** `-i` / `--interactive` (PowerShell: `-Interactive`) shows a numbered menu of installed non-embedding models and validates the choice (out of range or non-numeric input re-prompts; end of input exits 3).
   - It also runs automatically when the tool is in an interactive terminal and no model was given on the command line or in the config.
   - If more than one server responds, offer a server choice first.
   - Never prompt when not attached to a terminal (scripts, pipes, CI); fall back to the default model so scripted runs behave as before.
   - Draw the menu on the terminal, not stdout, so it never appears in piped output.
3. **Model validation:** `-m` / `--model` (PowerShell: `-Model`) is checked against the installed list. An unknown or embedding model prints an error plus the installed list and exits 3. For Ollama, accept the name with or without `:latest`.
4. **Config file:** `-c` / `--config <file>` (PowerShell: `-Config`), plus a default config file if present.
   - Format: plain `KEY=value` lines. Keys: `SERVER`, `URL`, `MODEL`, `LOG`, `SESSION_LOG`, `OUTPUT`, `SKIP_LIVE`, `NO_COLOR`. Booleans accept 0/1, true/false, yes/no. Strip matching quotes and trailing ` # comments`.
   - Parse safely: never source, eval, or dot-include the file. Warn on unknown keys and malformed lines, then continue.
   - Precedence: command line, then config file, then auto-detect/defaults.
   - Default locations: macOS `./local-llm-checkup.conf` next to the script or `~/.config/local-llm-checkup/config`; Linux the same two; Windows `local-llm-checkup.conf` next to the script or `%APPDATA%\local-llm-checkup\config`.
   - Ship a `local-llm-checkup.conf.example` and git-ignore the real config file.
5. **Report:** the report header records how the model was chosen (CLI, config, interactive, or default) and the config file path used, or "none".
6. **Model context maximum (C2):** Ollama caps the loaded context at the model's trained maximum (`ollama show <model>` "context length", or `/api/show` `model_info["<arch>.context_length"]`), so read it and show it next to the loaded context. When loaded context is below 64,000 and equals that maximum, keep the same WARN/FAIL thresholds but say the setting cannot raise it, and recommend a model with a larger trained context instead of changing `OLLAMA_CONTEXT_LENGTH`. If the maximum can't be read, fall back to the existing advice.

Exit codes are unchanged (0 all pass, 1 warn, 2 fail, 3 tool error). The tools still never change any system or application configuration.
