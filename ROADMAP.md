# Roadmap

Where VFR Radio is today and where it's headed. This is a training aid for
practicing VFR radio calls out loud — see the [README](README.md) for what it is
and how to run it.

Status is best-effort and changes as the project moves. Suggestions and pull
requests are welcome.

## Shipped

**Drill library** — 76 drills across three environments:

- **Untowered (CTAF):** full pattern work, position/intentions calls, straight-in
  etiquette, traffic negotiation, tower-closed CTAF switch.
- **Towered (ATC):** ground/taxi, tower, pattern, after-landing, plus curveballs
  — line-up-and-wait, hold-short crossings, go-around, extend downwind, wake
  turbulence, the option, Class D transition, complex multi-segment taxi.
- **Flight following:** initial callup, full request, squawk readback/verify,
  traffic advisories, vectors, frequency/sector handoffs, restrictions, terminate.
- **Airspace, emergencies & abnormals:** Class B/C/D rules, mayday, lost comms
  (7600), say-again, minimum vs. emergency fuel, weather diversion, LAHSO.

**Realism & grading**

- Grading against real-world FAA/AIM VFR phraseology, with adjustable difficulty
  (student → checkride → rapid-fire).
- Per-session variation: ATIS letters, distances, squawk codes, runway choice,
  and cruise altitude vary so a category isn't the same twice.
- App-composed instruction chaining: request → clearance → readback (and
  mid-taxi amendments), so a taxi clearance you read back matches what was issued.
- Multi-airport **trips**: intermediate stops are full-stop visits with the whole
  ground game, chained end to end.

**Clients**

- **iOS app** — hands-free voice loop (on-device speech in and out), designed to
  be usable while driving; optional over-the-air radio audio effect.
- **Web app** — push-to-talk and typed input, deployable free to GitHub Pages.
- **Shared-key proxy** — optional Cloudflare Worker so a class can share one key
  behind a passcode.

## Planned

- **Web/native parity** — port the remaining engine pieces to the web client:
  the full substitution randomizer (taxiway shuffle, squawk digits), trip
  builder, aircraft-fleet retargeting, and per-role voices.
- **Custom airports** — user-entered fields (same add/edit/delete flow as the
  custom aircraft fleet), usable in trips.
- **Real ATIS generation** — a spoken broadcast to copy, then use the letter.
- **Denser traffic realism** — richer background chatter and stepped-on
  transmissions.
- **CarPlay** — first-class support for the driving use case (native app).

## Contributing

Drill content is authored once in Swift
(`Packages/VFRCore/Sources/VFRCore/Drills.swift`) and generated to JSON for the
web client, so both clients stay in sync — see the READMEs in [`web/`](web/) and
[`worker/`](worker/). New drills, phraseology corrections, and airport-data fixes
are all welcome.

> Not affiliated with the FAA. A training aid, not a substitute for a CFI or
> official materials.
