# 🐝 pollinations-roblox

**Give your Roblox NPCs conversations powered by [Pollinations](https://pollinations.ai) — with a few lines of Luau.**

A server-side Luau client for the Pollinations text APIs (`Pollinations.chat(...)`) plus an NPC
dialogue helper with per-NPC conversation memory (`NpcDialogue.new(...)`). Ships with a ready-to-
open **example place** (`example-place.rbxlx`) containing **Bella the Beekeeper**, a talking NPC.

- ✅ Zero dependencies — two ModuleScripts, drop them in ReplicatedStorage
- ✅ Never throws on API failures — every call returns `{ ok = true|false, ... }`
- ✅ Automatic retries (429 / 5xx) with exponential backoff
- ✅ Works with Roblox's [secrets store](https://create.roblox.com/docs/cloud-services/secrets) (`HttpService:GetSecret`) or a plain key string
- ✅ Any model from the [live model list](https://gen.pollinations.ai/text/models) (default `openai/gpt-5.4-nano`)
- ✅ Verified: `luau-lsp analyze` clean against Roblox type definitions, **30/30 unit tests** pass (plain Luau + lune + TestEZ adapter included)

---

## Install

### Option A — Rojo (recommended)

1. Clone this repo:
   ```bash
   git clone https://github.com/Guest453/pollinations-roblox.git
   cd pollinations-roblox
   ```
2. [Install Rojo](https://rojo.space/docs/installation) if you haven't (`cargo install rojo` or download from [releases](https://github.com/rojo-rbx/rojo/releases)).
3. Open the place **and** sync the source in one go:
   ```bash
   rojo build default.project.json -o example-place.rbxlx   # build the example place
   rojo serve                                               # live-sync into Studio
   ```
4. In Roblox Studio: open `example-place.rbxlx`, then connect the Rojo plugin to `rojo serve` —
   or just open `example-place.rbxlx` alone; the modules are already baked into it.

### Option B — Wally

```toml
# wally.toml
[dependencies]
Pollinations = "pollinations/pollinations-roblox@1.0.0"
```

```bash
wally install
```

### Option C — copy two files

Copy [`src/Pollinations.lua`](src/Pollinations.lua) and [`src/NpcDialogue.lua`](src/NpcDialogue.lua)
into `ReplicatedStorage` as ModuleScripts. Done.

---

## Quick start (the whole thing is ~10 lines)

Put this in a **Script** inside `ServerScriptService` (HttpService is server-only!):

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Pollinations = require(ReplicatedStorage.Pollinations)
local NpcDialogue = require(ReplicatedStorage.NpcDialogue)

local npc = NpcDialogue.new(Pollinations, {
	Name = "Bella the Beekeeper",
	Persona = "You are Bella, a friendly bee-keeper NPC. Keep replies under 2 sentences.",
	Model = "openai/gpt-5.4-nano", -- any model from https://gen.pollinations.ai/text/models
})

local result = npc:Say("what do you sell?")
print(result.ok and result.content or result.error)
```

A complete, wired-up demo (ProximityPrompt → chat → speech bubble) lives in
[`demo/DemoServer.server.lua`](demo/DemoServer.server.lua) and is baked into the example place.

### Low-level client

```luau
local result = Pollinations.chat("openai/gpt-5.4-nano", {
	{ role = "system", content = "You are a pirate." },
	{ role = "user", content = "hello!" },
}, { Temperature = 0.8, MaxTokens = 120 })

if result.ok then
	print(result.content)          -- "Ahoy, matey! 🦜"
	print(result.usage)            -- token usage table
else
	warn(result.kind, result.error) -- "auth" | "rate_limit" | "server" | "network" | "http" | "parse" | "encode" | "bad_request"
end
```

Other calls: `Pollinations.ask(prompt)` (one-shot `GET /text/{prompt}`),
`Pollinations.listModels()` (live model list), `npc:GetHistory()`, `npc:ClearHistory()`.

---

## API key setup (server-side only!)

1. Get a free key at **https://enter.pollinations.ai/keys** (spends Pollen).
2. Add it to Roblox's **secrets store** so it never appears in code:
   [Creator Dashboard](https://create.roblox.com/dashboard/creations) → your experience →
   **Secrets → Create Secret** → name `pollinations_key`, domain `gen.pollinations.ai`.
3. Wire it up **in a server script**:

```luau
local HttpService = game:GetService("HttpService")
local Pollinations = require(ReplicatedStorage.Pollinations)

Pollinations.Configure({
	ApiKey = HttpService:GetSecret("pollinations_key"),
})
```

> Secrets only work on **live servers** and in collaborative testing — in normal Studio playtests
> you'll get `Can't find secret with given key` (expected!). For local testing, add the key under
> **File → Experience Settings → Security → Local Secrets**, or temporarily pass
> `{ ApiKey = "pk_..." }` — never commit a raw key to git.
>
> Anonymous requests (no key) sometimes work on free-tier models but are rate-limited and
> unreliable — always configure a key for your game.

Also enable **Allow HTTP Requests**: File → Experience Settings → Security →
**Allow HTTP Requests** ✅

> Roadmap note: players paying with their **own Pollinations account** (BYOP via the browser
> device flow) isn't practical inside Roblox today — there is no clean way to open a browser and
> complete an OAuth loop from the engine. The experience owner supplies the key; per-player
> billing can be layered on top with Roblox's own currency/datastore patterns.

---

## The example place ("Pollen Village")

`example-place.rbxlx` (build it with `rojo build`, or grab it from the CI artifacts) contains:

- A grass baseplate, spawn, and a wooden sign ("Welcome to Pollen Village")
- **Bella the Beekeeper** — a part-based NPC with a ProximityPrompt (`Press E to Talk`)
- `demo/DemoServer.server.lua` — the whole integration (~100 lines):
  1. Player walks up and presses **E** → greeting speech bubble
  2. Player types in Roblox chat (**/** key) while near Bella → every message goes to Bella's
     `Say()` with **per-player** conversation memory
  3. Bella replies as a speech bubble above her head, powered by a Pollinations text model
  4. Say `bye` → conversation clears

**Honest note about verification:** this repo was built in a headless Linux environment with
**no Roblox Studio available**. What was verified: `luau-lsp analyze` (with official Roblox type
definitions) passes on all sources, the 30-test suite passes under the real Luau runtime, the
HTTP request shape was verified against the live `gen.pollinations.ai` API, and the place file is
generated by Rojo 7.7.0 from a validated project. What was **not** verified: playing the place
inside Studio. If anything trips, it'll be Roblox-side wiring (e.g. Allow HTTP Requests), and the
error kinds make that obvious at runtime.

### Publishing it yourself (2 minutes)

1. Download `example-place.rbxlx` (from a [CI run artifact](https://github.com/Guest453/pollinations-roblox/actions)
   or `rojo build default.project.json -o example-place.rbxlx`).
2. In **Roblox Studio**: File → Open from File → `example-place.rbxlx`.
3. Add your API key (see setup above) → File → Publish to Roblox.
4. In [Creator Dashboard](https://create.roblox.com/dashboard/creations) → the experience →
   Settings → Permissions → set to **Public**.
5. Play it: Creations → your experience → **Launch** (or share the place URL from the experience page).

---

## Tests

```bash
# plain Luau (no deps):
luau tests/test_pollinations.luau
# or with lune:
lune run tests/run_lune.luau
```

30 tests cover: URI encoding, backoff, status classification, message validation, JSON
encode/decode (against real captured API bodies), chat() happy path + auth/rate-limit/server/
parse failures + retry-with-backoff + per-call overrides, ask(), listModels(), and NPC history
(build/trim/isolation/no-pollution-on-failure). A TestEZ adapter (`tests/testez_spec.luau`) runs
the same assertions inside Studio.

## Project layout

```
src/Pollinations.lua       ← the client (chat / ask / listModels / Configure)
src/NpcDialogue.lua        ← NPC helper (persona + per-NPC memory)
demo/DemoServer.server.lua ← full example NPC wired to a ProximityPrompt + chat
default.project.json       ← Rojo project for the example place
example-place.rbxlx        ← built place (rojo build)
tests/                     ← 30-test suite (plain Luau / lune / TestEZ)
tools/                     ← vendored Luau toolchain used by CI (not needed at runtime)
```

## License

MIT
