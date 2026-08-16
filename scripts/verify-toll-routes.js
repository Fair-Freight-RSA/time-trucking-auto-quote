const fs = require("node:fs");

const env = Object.fromEntries(
  fs.readFileSync(".env", "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#") && line.includes("="))
    .map((line) => {
      const index = line.indexOf("=");
      return [line.slice(0, index), line.slice(index + 1)];
    })
);

const googleKey = env.VITE_GOOGLE_MAPS_API_KEY || process.env.GOOGLE_ROUTES_API_KEY;
if (!googleKey) throw new Error("Google Routes key is not configured.");

const plazas = [
  { name: "De Hoek Mainline Plaza", road: "N3", operator: "N3TC", type: "mainline", lat: -26.7256385, lon: 28.4147685, c4: 230, source: "SANRAL 2026 poster / Gazette 54087-54088" },
  { name: "Wilge Mainline Plaza", road: "N3", operator: "N3TC", type: "mainline", lat: -27.1008650, lon: 28.6648159, c4: 304, source: "SANRAL 2026 poster / Gazette 54087-54088" },
  { name: "Tugela Mainline Plaza", road: "N3", operator: "N3TC", type: "mainline", lat: -28.4480585, lon: 29.5313636, c4: 359, source: "SANRAL 2026 poster / Gazette 54087-54088" },
  { name: "Mooi Mainline Plaza", road: "N3", operator: "N3TC", type: "mainline", lat: -29.1991016, lon: 29.9984886, c4: 324, source: "SANRAL 2026 poster / Gazette 54087-54088" },
  { name: "Mariannhill Mainline Plaza", road: "N3", operator: "SANRAL", type: "mainline", lat: -29.82302, lon: 30.80276, c4: 57, source: "SANRAL 2026 poster / Gazette 54087-54088; coordinate cross-check Mapcarta/OpenStreetMap" },
  { name: "Grasmere Mainline Plaza", road: "N1", operator: "SANRAL", type: "mainline", lat: -26.41711, lon: 27.88075, c4: 126, source: "SANRAL 2026 poster / Gazette 54087-54088; coordinate cross-check Mapcarta/OpenStreetMap" },
  { name: "Vaal Mainline Plaza", road: "N1", operator: "SANRAL", type: "mainline", lat: -26.85639, lon: 27.63528, c4: 275, source: "SANRAL 2026 poster / Gazette 54087-54088; coordinate cross-check public map/gazette references" },
  { name: "Verkeerdevlei Mainline Plaza", road: "N1", operator: "SANRAL", type: "mainline", lat: -28.79889, lon: 26.69056, c4: 331, source: "SANRAL 2026 poster / Gazette 54087-54088; coordinate cross-check public map/gazette references" },
  { name: "Huguenot Mainline Plaza", road: "N1", operator: "SANRAL", type: "mainline", lat: -33.7428, lon: 19.0197, c4: 383, source: "SANRAL 2026 poster / Gazette 54087-54088; coordinate cross-check public map/gazette references" },
  { name: "Brits Mainline", road: "N4", operator: "Bakwena", type: "mainline", lat: -25.65, lon: 27.922, c4: 90, source: "Bakwena 2026 official tariff" },
  { name: "Marikana Mainline", road: "N4", operator: "Bakwena", type: "mainline", lat: -25.7473333, lon: 27.3976667, c4: 96, source: "Bakwena 2026 official tariff" },
  { name: "Diamond Hill Mainline", road: "N4", operator: "TRAC", type: "mainline", lat: -25.8269204, lon: 28.7747179, c4: 220, source: "TRAC N4 2026 official tariff" },
  { name: "Middelburg Mainline", road: "N4", operator: "TRAC", type: "mainline", lat: -25.8291941, lon: 29.5315046, c4: 365, source: "TRAC N4 2026 official tariff" },
  { name: "Machado Mainline", road: "N4", operator: "TRAC", type: "mainline", lat: -25.6291484, lon: 30.2572981, c4: 729, source: "TRAC N4 2026 official tariff" },
  { name: "Nkomazi Mainline", road: "N4", operator: "TRAC", type: "mainline", lat: -25.5361985, lon: 31.3443903, c4: 405, source: "TRAC N4 2026 official tariff" }
];

function decodePolyline(encoded) {
  let index = 0;
  let lat = 0;
  let lng = 0;
  const coordinates = [];
  while (index < encoded.length) {
    let b;
    let shift = 0;
    let result = 0;
    do {
      b = encoded.charCodeAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lat += (result & 1) ? ~(result >> 1) : (result >> 1);
    shift = 0;
    result = 0;
    do {
      b = encoded.charCodeAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lng += (result & 1) ? ~(result >> 1) : (result >> 1);
    coordinates.push({ latitude: lat / 1e5, longitude: lng / 1e5 });
  }
  return coordinates;
}

function radians(value) {
  return value * Math.PI / 180;
}

function metersBetween(left, right) {
  const earthRadiusMeters = 6371008.8;
  const dLat = radians(right.latitude - left.latitude);
  const dLon = radians(right.longitude - left.longitude);
  const lat1 = radians(left.latitude);
  const lat2 = radians(right.latitude);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * earthRadiusMeters * Math.asin(Math.sqrt(h));
}

function distanceToSegmentMeters(point, a, b) {
  const latScale = 111320;
  const lonScale = 111320 * Math.cos(radians((a.latitude + b.latitude) / 2));
  const ax = a.longitude * lonScale;
  const ay = a.latitude * latScale;
  const bx = b.longitude * lonScale;
  const by = b.latitude * latScale;
  const px = point.longitude * lonScale;
  const py = point.latitude * latScale;
  const dx = bx - ax;
  const dy = by - ay;
  const lengthSq = dx * dx + dy * dy;
  if (lengthSq === 0) return metersBetween(point, a);
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSq));
  const projected = { longitude: (ax + t * dx) / lonScale, latitude: (ay + t * dy) / latScale };
  return metersBetween(point, projected);
}

function secondsFromDuration(value) {
  const match = String(value || "").match(/^(\d+(?:\.\d+)?)s$/);
  return match ? Number(match[1]) : 0;
}

async function route(origin, destination) {
  const response = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-Goog-Api-Key": googleKey,
      "X-Goog-FieldMask": "routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.travelAdvisory.tollInfo,routes.description,routes.warnings"
    },
    body: JSON.stringify({
      origin: { address: origin },
      destination: { address: destination },
      travelMode: "DRIVE",
      routingPreference: "TRAFFIC_UNAWARE",
      computeAlternativeRoutes: false,
      extraComputations: ["TOLLS"],
      polylineQuality: "OVERVIEW",
      units: "METRIC"
    })
  });
  const body = await response.json();
  if (!response.ok) throw new Error(JSON.stringify(body));
  const selected = body.routes?.[0];
  if (!selected) throw new Error(`No Google route for ${origin} -> ${destination}`);
  const points = decodePolyline(selected.polyline.encodedPolyline);
  const matches = [];
  for (const plaza of plazas) {
    const point = { latitude: plaza.lat, longitude: plaza.lon };
    let bestDistance = Number.POSITIVE_INFINITY;
    let bestSegment = 0;
    for (let index = 0; index < points.length - 1; index += 1) {
      const distance = distanceToSegmentMeters(point, points[index], points[index + 1]);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestSegment = index;
      }
    }
    const threshold = plaza.type === "ramp" ? 180 : 900;
    const confidenceRatio = Math.max(0, 1 - (bestDistance / threshold));
    if (bestDistance <= threshold && !(plaza.type === "ramp" && confidenceRatio < 0.72)) {
      matches.push({
        plaza: plaza.name,
        road: plaza.road,
        operator: plaza.operator,
        type: plaza.type,
        toll_class: 4,
        amount: plaza.c4,
        source: plaza.source,
        distance_m: Number(bestDistance.toFixed(1)),
        route_order: bestSegment
      });
    }
  }
  matches.sort((a, b) => a.route_order - b.route_order || a.distance_m - b.distance_m);
  const total = matches.reduce((sum, match) => sum + match.amount, 0);
  const tollStatus = selected.travelAdvisory?.tollInfo ? "available_or_expected_unknown" : "unavailable";
  const status = matches.length ? "SAFE AUTOMATIC" : (tollStatus === "available_or_expected_unknown" ? "REVIEW REQUIRED" : "NO TOLLS");
  return {
    origin,
    destination,
    distance_km: Number((selected.distanceMeters / 1000).toFixed(1)),
    duration_hours: Number((secondsFromDuration(selected.duration) / 3600).toFixed(2)),
    google_toll_status: tollStatus,
    matched_plazas: matches,
    total_class_4: total,
    status
  };
}

(async () => {
  const cases = [
    ["Johannesburg, South Africa", "Durban, South Africa"],
    ["Johannesburg, South Africa", "Cape Town, South Africa"],
    ["Johannesburg, South Africa", "Pretoria, South Africa"],
    ["Pretoria, South Africa", "Rustenburg, South Africa"],
    ["Pretoria, South Africa", "Komatipoort, South Africa"]
  ];
  const results = [];
  for (const [origin, destination] of cases) {
    results.push(await route(origin, destination));
  }
  console.log(JSON.stringify(results, null, 2));
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
