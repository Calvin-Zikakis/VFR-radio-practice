// Coordinates for the routable airports, used only by the web map route builder.
// (The shared drill data has no lat/lon, so these live web-side.) Values are the
// airports' published reference points, good enough to place a marker.

export const AIRPORT_COORDS: Record<string, { lat: number; lon: number }> = {
  KWVI: { lat: 36.9357, lon: -121.7896 }, // Watsonville
  E16: { lat: 37.0819, lon: -121.5966 }, // South County (San Martin)
  KCVH: { lat: 36.8927, lon: -121.4103 }, // Hollister
  KHAF: { lat: 37.5134, lon: -122.5011 }, // Half Moon Bay
  KOAR: { lat: 36.682, lon: -121.7623 }, // Marina
  KSNS: { lat: 36.6628, lon: -121.6064 }, // Salinas
  KPAO: { lat: 37.4611, lon: -122.115 }, // Palo Alto
  KLVK: { lat: 37.6934, lon: -121.8203 }, // Livermore
  KMRY: { lat: 36.587, lon: -121.843 }, // Monterey
  KRHV: { lat: 37.3329, lon: -121.8197 }, // Reid-Hillview
  KSQL: { lat: 37.5119, lon: -122.2495 }, // San Carlos
  KCCR: { lat: 37.9897, lon: -122.0568 }, // Concord (Buchanan)
};
