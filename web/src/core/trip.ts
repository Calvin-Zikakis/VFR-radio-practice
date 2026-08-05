// Port of TripBuilder.swift — turns an ordered route (list of airports) into a
// drill sequence: taxi, departure, flight following, arrival, pattern, adapted
// to towered/untowered fields. Kept in step with the Swift original; the chained
// phases carry authored instructionVariants that the session resolves + reads
// back, exactly like the library drills.

import type { Aircraft, Airport, Drill, ScenarioType, CallType } from "./types";

function firstRunway(ap: Airport): string {
  return ap.runwaysInUse[0] ?? "the active";
}

/** "31" → "three one", "28R" → "two eight right". */
export function spokenRunway(r: string): string {
  const map: Record<string, string> = {
    "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
    "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "niner",
    L: "left", R: "right", C: "center",
  };
  const words = r.toUpperCase().split("").map((c) => map[c]).filter(Boolean);
  return words.length ? words.join(" ") : r;
}

function atisLetter(): string {
  const xs = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Quebec", "Zulu"];
  return xs[Math.floor(Math.random() * xs.length)];
}

function callTypeFromTitle(title: string, scenario: ScenarioType): CallType {
  if (title.includes("Taxi") && !title.includes("self-announce")) return "taxi";
  if (title.includes("Taxi self-announce")) return "taxi";
  if (title.includes("departure") || title.includes("Departing")) return "departure";
  if (title.includes("Traffic advisory")) return "advisory";
  if (title.includes("pattern") || title.includes("Downwind") || title.includes("Base")) return "pattern";
  if (title.includes("Clear of the runway")) return "afterLanding";
  if (title.includes("Inbound")) return "arrival";
  if (scenario === "flightFollowing") return "flightFollowing";
  return "arrival";
}

export function tripDrills(
  stops: Airport[],
  flightFollowing: boolean,
  patternWork: boolean,
  aircraft: Aircraft
): Drill[] {
  if (stops.length < 2) return [];
  const out: Drill[] = [];
  let n = 0;
  const add = (
    scenario: ScenarioType,
    title: string,
    setup: string,
    situation: string,
    ap: Airport
  ) => {
    n += 1;
    out.push({
      id: `trip-${n}`,
      scenario,
      title,
      setup,
      situation,
      aircraft,
      airport: ap,
      callType: callTypeFromTitle(title, scenario),
    });
  };

  const origin = stops[0];
  const destination = stops[stops.length - 1];
  // For the enroute flight-following request (issued right after departing the
  // origin), name the outbound leg's destination. On a round trip the final stop
  // IS the origin, so "en route to <origin>" would be nonsense — use stops[1].
  const ffDest = destination.icao !== origin.icao ? destination : stops[1];
  const cs = aircraft.phoneticCallsign;

  const departure = (ap: Airport, dest: string) => {
    const rwy = spokenRunway(firstRunway(ap));
    if (ap.isTowered) {
      const atis = atisLetter();
      add("towered", `Taxi — ${ap.name} Ground`,
        `You're at ${ap.name} with information ${atis}, parked at the ramp, ready to taxi for a VFR departure toward ${dest}. Call ${ap.name} Ground.`,
        `Towered field, you are ${ap.name} Ground. Runway ${firstRunway(ap)} in use. Grade the request: who they're calling, aircraft, position, the ATIS letter (current is information ${atis}; a different letter gets 'verify you have information ${atis}'), request, and direction of flight.`,
        ap);
      add("towered", `Ready for departure — ${ap.name} Tower`,
        `You're holding short of runway ${rwy} at ${ap.name}, ready for a VFR departure toward ${dest}. Call the tower.`,
        `Towered field, you are ${ap.name} Tower. Pilot is holding short runway ${firstRunway(ap)} requesting a VFR departure. Expect who they're calling, aircraft, position (holding short), and request/intentions.`,
        ap);
    } else {
      add("untowered", `Taxi self-announce — ${ap.name}`,
        `You're at ${ap.name}, about to taxi from the ramp for departure on runway ${rwy}. Make your taxi call.`,
        `Uncontrolled field (${ap.name}). Pilot is taxiing to runway ${firstRunway(ap)}. Expect a CTAF self-announce: airport, aircraft, where they're taxiing (to runway ${firstRunway(ap)}), airport again. A taxi call does NOT require departure intentions or direction of flight — never ask for those here; they belong in the departure call.`,
        ap);
      add("untowered", `Departing — ${ap.name}`,
        `You're holding short of runway ${rwy} at ${ap.name}, ready to depart toward ${dest}. Make your departure call.`,
        `Uncontrolled field (${ap.name}). Pilot is departing runway ${firstRunway(ap)} on course toward ${dest}. Expect airport, aircraft, departing runway ${firstRunway(ap)}, direction/intentions, airport again. No controller reply; other traffic may respond.`,
        ap);
    }
  };

  const arrival = (ap: Airport, detailed: boolean) => {
    const rwy = spokenRunway(firstRunway(ap));
    const intent = "to land, full stop";
    const atis = atisLetter();
    if (ap.isTowered) {
      add("towered", `Inbound — ${ap.name} Tower`,
        `You're 10 miles from ${ap.name} at two thousand five hundred, inbound ${intent}, with information ${atis}. Call ${ap.name} Tower.`,
        `Towered field, you are ${ap.name} Tower. Pilot is 10 miles out at 2,500 inbound ${intent} with ATIS ${atis}. Expect who they're calling, aircraft, position and altitude, the ATIS letter, and request.`,
        ap);
      if (detailed) {
        add("towered", `Report the pattern — ${ap.name} Tower`,
          `${ap.name} Tower told you to report a left downwind for runway ${rwy}. Make that report.`,
          `Towered field, you are ${ap.name} Tower. Pilot was told to report left downwind. Expect callsign plus position ('left downwind runway ${firstRunway(ap)}'). Reply with the landing clearance or the option — or sequence them with traffic ('number two, report base'). If you sequence them, the exchange is NOT over: expect the readback, then their base report, then issue the landing clearance. Set phaseAdvance only once the landing (or option) clearance has been issued and read back — never right after asking for a report you haven't received.`,
          ap);
      }
      add("towered", `Clear of the runway — ${ap.name} Ground`,
        `You've landed at ${ap.name} and are clear of runway ${rwy}. The tower said contact ground. Call ${ap.name} Ground to taxi to parking.`,
        `Towered field, you are ${ap.name} Ground. Pilot just cleared the runway. Expect who they're calling, aircraft, position, and a request to taxi to parking.`,
        ap);
    } else {
      add("untowered", `Inbound — ${ap.name}`,
        `You're 10 miles from ${ap.name}, inbound ${intent}. Make your inbound call.`,
        `Uncontrolled field (${ap.name}). Pilot is 10 miles out inbound ${intent}. Expect airport, aircraft, position and altitude, intentions, a request for airport advisories, airport again.`,
        ap);
      if (detailed) {
        add("untowered", `Downwind — ${ap.name}`,
          `You're entering a left downwind for runway ${rwy} at ${ap.name}, ${intent}. Make your downwind call.`,
          `Uncontrolled field (${ap.name}). Pilot is on left downwind for runway ${firstRunway(ap)}. Expect airport, aircraft, position in the pattern, intentions (${intent}), airport again.`,
          ap);
        add("untowered", `Base and final — ${ap.name}`,
          `You're turning left base for runway ${rwy} at ${ap.name}, ${intent}. Make your base call.`,
          `Uncontrolled field (${ap.name}). Pilot is turning base to final for runway ${firstRunway(ap)}. Expect airport, aircraft, position, intentions, airport again.`,
          ap);
      }
      add("untowered", `Clear of the runway — ${ap.name}`,
        `You've landed and taxied clear of runway ${rwy} at ${ap.name}. Make your call.`,
        `Uncontrolled field (${ap.name}). Pilot has exited the runway. Expect a brief self-announce that they are clear of runway ${firstRunway(ap)}, airport name. Keep it short.`,
        ap);
    }
  };

  departure(origin, stops[1].name);

  if (flightFollowing) {
    add("flightFollowing", "Initial callup — NorCal Approach",
      `You've departed ${origin.name} and want to check in with NorCal Approach for flight following, but haven't given details yet. Make just your brief initial callup.`,
      `You are NorCal Approach, and you are busy. Best practice on a busy frequency is a brief initial callup: facility, aircraft, and 'request VFR flight following' or 'with a request'. Reply with 'go ahead' or 'say request'. Grade whether the pilot kept it brief and did not dump all the details at once.`,
      origin);
    add("flightFollowing", "Request flight following — NorCal Approach",
      `NorCal Approach answers 'go ahead'. You're climbing through two thousand five hundred, en route to ${ffDest.name} at four thousand five hundred. Make your request.`,
      `You are NorCal Approach. The pilot is following up their initial callup. Expect: aircraft type/callsign, position and altitude, request (VFR flight following), destination (${ffDest.name}), and requested altitude. While anything is missing, ask only for the missing item.`,
      origin);
    add("flightFollowing", "Traffic advisory",
      `You're on flight following with NorCal Approach. NorCal calls: traffic, two o'clock, three miles, opposite direction, a Cirrus, altitude indicates three thousand five hundred. Respond appropriately.`,
      `You are NorCal Approach. You just issued a traffic advisory (2 o'clock, 3 miles, opposite direction, a Cirrus at 3,500). Grade the pilot's response: callsign plus 'looking', 'traffic in sight', or 'negative contact'. Reply only if a follow-up is warranted.`,
      origin);
    add("flightFollowing", "Traffic vector",
      `NorCal calls: ${cs}, traffic twelve o'clock, five miles, opposite direction — turn right heading zero four zero. Read back the vector; you'll be put back on course once clear.`,
      `You are NorCal Approach. Step 1: you issued 'turn right heading zero four zero' for traffic — grade the readback (heading plus callsign; a bare 'roger' is not acceptable for a heading). Step 2: after a correct readback, call 'traffic no longer a factor, resume own navigation' and grade the acknowledgment (own nav plus callsign). Set phaseAdvance true only after both steps.`,
      origin);
    add("flightFollowing", "Frequency handoff",
      `NorCal Approach calls: ${cs}, contact NorCal Approach now on one three four point five. Read back the handoff, then check in on the new frequency.`,
      `You are NorCal Approach handing the pilot to the next sector as they progress. Step 1: read back the new frequency and callsign ('one three four point five, ${cs}'). Step 2, on the new frequency, a brief check-in: facility, callsign, and current altitude — no re-request of flight following. Set phaseAdvance true only once they've read back the handoff AND checked in; otherwise ask for the missing part.`,
      origin);
  }

  for (const stop of stops.slice(1, -1)) {
    arrival(stop, patternWork);
    departure(stop, destination.name);
  }

  if (flightFollowing) {
    add("flightFollowing", "Terminate flight following",
      `You're on flight following with NorCal Approach and you have ${destination.name} in sight, ready to cancel. Make your call.`,
      `You are NorCal Approach. The pilot has their destination in sight and wants to terminate flight following. Expect callsign, 'airport in sight', and 'cancel flight following' or 'request frequency change'. Reply with 'radar service terminated, squawk VFR, frequency change approved'.`,
      destination);
  }

  arrival(destination, patternWork);

  // Chained phases carry authored instruction variants (mirrors the Swift pass).
  for (let i = 0; i < out.length; i++) {
    const t = out[i].title;
    const ap = out[i].airport;
    const rwy = spokenRunway(firstRunway(ap));
    let variants: string[] | undefined;
    if (t.startsWith("Ready for departure —")) {
      variants = [
        `${cs}, runway ${rwy}, cleared for takeoff.`,
        `${cs}, runway ${rwy}, line up and wait, traffic departing ahead.`,
        `${cs}, runway ${rwy}, cleared for takeoff, on-course heading approved.`,
      ];
    } else if (t.startsWith("Request flight following —")) {
      variants = [`${cs}, squawk four five two one.`, `${cs}, squawk four five two one and ident.`];
    } else if (t.startsWith("Taxi —") && t.endsWith("Ground")) {
      variants = [
        `${cs}, ${ap.name} Ground, runway ${rwy}, taxi via alpha.`,
        `${cs}, ${ap.name} Ground, runway ${rwy}, taxi via bravo, alpha.`,
      ];
    } else if (t.startsWith("Clear of the runway —") && t.endsWith("Ground")) {
      variants = [
        `${cs}, ${ap.name} Ground, taxi to parking via alpha.`,
        `${cs}, ${ap.name} Ground, taxi to the transient ramp via alpha, bravo.`,
      ];
    } else if (t.startsWith("Inbound —") && t.endsWith("Tower")) {
      const reportsDownwindNext =
        i + 1 < out.length && out[i + 1].title.startsWith("Report the pattern");
      variants = reportsDownwindNext
        ? [
            `${cs}, ${ap.name} Tower, enter left downwind runway ${rwy}, report midfield.`,
            `${cs}, ${ap.name} Tower, enter left downwind runway ${rwy}, report midfield, traffic is a Cessna ahead on the downwind.`,
          ]
        : [
            `${cs}, ${ap.name} Tower, enter left downwind runway ${rwy}, report midfield.`,
            `${cs}, ${ap.name} Tower, make straight-in runway ${rwy}, report three mile final.`,
          ];
    }
    if (variants) {
      out[i].followUpReadback = true;
      out[i].instructionVariants = variants;
    }
  }
  return out;
}
