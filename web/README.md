# VFR Radio — Web

A browser version of the VFR radio practice app: speak (or type) a VFR radio
call, Claude grades your phraseology and replies in the controller's voice.
Pure static site — no server needed for the "bring your own key" mode.

Works best in **Chrome / Firefox** (desktop + Android). iOS Safari's speech
recognition is unreliable, so voice is best-effort there; the typed input always
works.

## Run it locally

```sh
cd web
npm install
npm run dev        # open the printed localhost URL
```

Then open **Settings** and either:

- **My own key** — paste an Anthropic API key (get one at
  [console.anthropic.com](https://console.anthropic.com): Billing → add ~$5
  credit → API Keys). It's stored only in your browser and calls Claude
  directly. Simplest for solo use.
- **Class passcode** — use the shared class key via the Worker (see below). Only
  works once a Worker is deployed and `VITE_WORKER_URL` is configured.

Pick a category, hold **🎙 Hold to talk** (or type), and make your call.

## The drill content is generated from Swift

The 76 drills are authored once in `Packages/VFRCore/Sources/VFRCore/Drills.swift`
and dumped to `web/src/core/drills.generated.json`. After editing a drill:

```sh
web/scripts/generate-drills.sh   # regenerates the JSON from Swift
```

The rest of the engine (grader prompt, session/readback chaining, verdict
cleaning) is ported to TypeScript in `web/src/core/` and kept in step with the
Swift original.

## Deploy to GitHub Pages (free)

Pushing to `main` with changes under `web/` triggers
`.github/workflows/deploy-web.yml`, which builds and publishes the site. One-time
setup: repo **Settings → Pages → Build and deployment → Source: GitHub Actions**.

For the shared "try it" mode, set a repo **Variable** (Settings → Secrets and
variables → Actions → Variables) named `VITE_WORKER_URL` to your deployed
Worker's URL (see `worker/README.md`). Leave it unset for a
bring-your-own-key-only site.

## Cost

Each graded call is one Claude API request (a few cents on Sonnet; less on
Haiku). In bring-your-own-key mode you pay your own usage; in shared mode the
class key does. Switch the model in Settings.
