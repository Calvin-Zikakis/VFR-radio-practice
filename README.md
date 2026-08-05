# VFR Radio — Practice

Practice VFR aviation radio calls **out loud**. You speak (or type) a radio call;
Claude understands it, replies in the appropriate controller/CTAF voice, and
grades your phraseology against real-world FAA/AIM VFR practice. Covers three
environments: **untowered (CTAF)**, **towered (ATC)**, and **flight following**.

Two clients share one drill library:

| | What | Where |
|---|---|---|
| **iOS app** | SwiftUI + on-device speech + `VFRCore` engine. Hands-free-while-driving is the design goal. | [`App/`](App/), [`Packages/VFRCore/`](Packages/VFRCore/) |
| **Web app** | TypeScript + Vite, deploys free to GitHub Pages. Push-to-talk + typed input, Chrome/Firefox. | [`web/`](web/) |
| **Shared-key proxy** | Optional Cloudflare Worker (Rust) so a class can share one key behind a passcode — free, no credit card. | [`worker/`](worker/) |

The 76 drills are authored once in Swift
([`Drills.swift`](Packages/VFRCore/Sources/VFRCore/Drills.swift)) and generated
to JSON for the web client, so both stay in sync.

## Bring your own key

Both clients call the **Claude API** and need an Anthropic API key
([console.anthropic.com](https://console.anthropic.com)). The key is never stored
in this repo:

- **iOS** keeps it in the device Keychain.
- **Web (bring-your-own)** keeps it in your browser's `localStorage` and calls
  Claude directly — a pure static site, no backend.
- **Web (shared class key)** routes through the Worker, which holds the key as a
  server-side secret. See [`worker/README.md`](worker/README.md).

## Run the web app

```sh
cd web && npm install && npm run dev
```

Open Settings, add your key (or the class passcode), pick a category, and make
your call. Full details: [`web/README.md`](web/README.md).

## Run the iOS app

Open the project with XcodeGen (`project.yml`) and run on a device. Engine tests:
`cd Packages/VFRCore && swift test`.

## License

No license yet — add one to make it truly open source (MIT and Apache-2.0 are
common permissive choices). Until a `LICENSE` file exists, default copyright
applies (all rights reserved).

> Not affiliated with the FAA. A training aid, not a substitute for a CFI or
> official materials.
