# VFR Radio — shared-key proxy (Cloudflare Worker)

A small Rust Worker that lets students use a **shared class key** without each
getting their own — the whole point being **free hosting with no credit card**.
It holds the class's Anthropic key server-side (never in the website), requires a
class passcode, and rate-limits per IP. It serves three POST endpoints:

- `/` (or `/grade`) — forwards a graded-call request to Claude.
- `/stt` — speech-to-text (Whisper on Workers AI): audio bytes → text.
- `/tts` — text-to-speech (MeloTTS on Workers AI): text → base64 audio.

Voice runs on Workers AI (free daily allowance, no card) so Firefox and Safari —
which lack the browser speech APIs — get voice both ways. Voice is optional: skip
its two secrets and `/grade` still works on the browser's own speech.

**Why this exists:** a static site can't hide a secret — a key put in the page's
JavaScript is readable by anyone and gets auto-disabled by Anthropic. The Worker
keeps the key on the server. Bring-your-own-key users skip it entirely.

## Safety model

1. The key lives as a **Worker secret**, never in the repo or the site.
2. The Worker checks a **class passcode** and **rate-limits per IP** (40
   req/hour) so a "try it" visitor can't hammer it.
3. Keep the key **prepaid with auto-reload OFF**. No card on file means a **hard
   ceiling**: worst case someone burns the loaded balance and the demo pauses
   until you top it up. No surprise bills are possible.

## Deploy (free, no credit card)

Prereqs: a free Cloudflare account and the Rust toolchain
(`rustup target add wasm32-unknown-unknown`). Install wrangler:
`npm install -g wrangler`, then `wrangler login`.

```sh
cd worker

# 1. Create the rate-limit KV namespace and paste its id into wrangler.toml
wrangler kv namespace create RATE_LIMIT

# 2. Store the secrets (never committed)
wrangler secret put ANTHROPIC_API_KEY      # your prepaid key, auto-reload OFF
wrangler secret put CLASS_PASSCODE         # the passcode you hand students

# 3. (Optional — for voice) enable Workers AI STT/TTS.
#    Create a free API token at dash.cloudflare.com → My Profile → API Tokens
#    → Create Token → permission "Account · Workers AI · Read". Copy your
#    account id from the dashboard URL / Workers overview.
wrangler secret put CF_ACCOUNT_ID          # your Cloudflare account id
wrangler secret put CF_AI_TOKEN            # the Workers AI token

# 4. Deploy
wrangler deploy
```

`wrangler deploy` prints the Worker URL (e.g.
`https://vfr-radio-proxy.<you>.workers.dev`). Put that in the site's
`VITE_WORKER_URL` repo variable (see `web/README.md`) and hand students the
passcode.

## Rotating / locking down

- Change the passcode: `wrangler secret put CLASS_PASSCODE` again.
- Change the key: `wrangler secret put ANTHROPIC_API_KEY` again.
- Adjust the per-IP limit: edit `MAX_PER_HOUR` in `src/lib.rs` and redeploy.

## Optional hardening

For a fully public "try it" link, add a free **Cloudflare Turnstile** check
(bot protection) in front of the passcode — verify the token in `src/lib.rs`
before forwarding. Not required if the passcode stays within a class.
