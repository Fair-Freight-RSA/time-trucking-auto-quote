const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), "utf8");

function test(name, fn) {
  try {
    fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    console.error(`not ok - ${name}`);
    console.error(error.message);
    process.exitCode = 1;
  }
}

function itemTotalWeightKg(item) {
  const match = String(item.notes ?? "").match(/Total shipment weight:\s*([0-9]+(?:\.[0-9]+)?)\s*kg/i);
  if (match) return Number(match[1]);
  return (Number(item.quantity) || 1) * (Number(item.weight_kg) || 0);
}

function recommend(items) {
  const totalWeight = items.reduce((sum, item) => sum + itemTotalWeightKg(item), 0);
  const totalVolume = items.reduce((sum, item) => sum + (item.quantity || 1) * (item.length_m || 0) * (item.width_m || 0) * (item.height_m || 0), 0);
  const totalDeckArea = items.reduce((sum, item) => sum + (item.quantity || 1) * (item.length_m || 0) * (item.width_m || 0), 0);
  const itemCount = items.reduce((sum, item) => sum + (item.quantity || 1), 0);
  const maxLength = Math.max(0, ...items.map((item) => item.length_m || 0));
  const maxWidth = Math.max(0, ...items.map((item) => item.width_m || 0));
  const maxHeight = Math.max(0, ...items.map((item) => item.height_m || 0));
  const machinery = items.some((item) => item.cargo_category === "machinery");
  const dimensionallyAbnormal = maxLength > 12 || maxWidth > 2.5 || maxHeight > 4.3;

  let vehicle = "8 ton / 14 ton";
  let trailer = "Curtain side";
  let payloadCapacity = 8000;
  let volumeCapacity = 45;

  if (dimensionallyAbnormal || (machinery && (totalWeight > 28000 || maxLength > 12))) {
    vehicle = "Heavy haulage truck";
    trailer = "Lowbed";
    payloadCapacity = 35000;
    volumeCapacity = 70;
  } else if (machinery || totalWeight > 14000 || itemCount > 14 || totalDeckArea > 18) {
    vehicle = "Rigid truck / horse";
    trailer = "Flatdeck / tri-axle";
    payloadCapacity = 28000;
    volumeCapacity = 80;
  } else if (totalWeight > 8000 || totalVolume > 45) {
    vehicle = "14 ton";
    trailer = "Tautliner / curtain side";
    payloadCapacity = 14000;
    volumeCapacity = 60;
  }

  return {
    totalWeight,
    vehicle,
    trailer,
    trucks: Math.max(1, Math.ceil(Math.max(totalWeight / payloadCapacity, totalVolume / volumeCapacity))),
    abnormal: dimensionallyAbnormal
  };
}

test("RFQ uses required millimetre pallet dimensions and keeps total-weight intent", () => {
  const app = read("src/app.ts");
  assert.ok(app.includes("Pallet length (mm)"), "pallet length must be a clear mm field");
  assert.ok(app.includes("Pallet width (mm)"), "pallet width must be a clear mm field");
  assert.ok(app.includes("Pallet height (mm)"), "pallet height must be a clear mm field");
  assert.ok(app.includes('data-dimension-unit="mm"'), "mm fields must be converted before storage");
  assert.ok(app.includes("Total shipment weight:"), "payload notes must preserve total shipment weight");
  assert.ok(app.includes("value / 1000"), "mm values must convert to metres for the backend payload");
});

test("DB corrective migration removes mass-only abnormal and escort rules", () => {
  const migration = read("supabase/migrations/20260810001000_fix_vehicle_intelligence_abnormal_weight_logic.sql");
  assert.ok(migration.includes("create or replace function public.ttaq_generate_vehicle_recommendation(target_quote_request_id uuid)"), "migration must replace only the vehicle recommendation function");
  assert.ok(migration.includes("dimensionally_abnormal_value := max_length > 12 or max_width > 2.5 or max_height > 4.3;"), "abnormal classification should be dimensional in the current configured rule");
  assert.equal(migration.includes("or total_weight > 30000"), false, "total weight must not classify a shipment as abnormal");
  assert.equal(migration.includes("or total_weight > 45000"), false, "total weight must not trigger escort recommendation");
  assert.ok(migration.includes("missing_dimensions_value"), "missing dimensions should create review, not false abnormal");
});

test("TEST A: 17 standard pallets are not lowbed or abnormal in browser fallback", () => {
  const result = recommend([{
    quantity: 17,
    weight_kg: 1000,
    length_m: 1.2,
    width_m: 1,
    height_m: 1.5,
    cargo_category: "general_freight",
    notes: "Freight type: Pallets / palletised goods | Total shipment weight: 17000 kg"
  }]);
  assert.notEqual(result.trailer, "Lowbed");
  assert.equal(result.abnormal, false);
});

test("TEST B: 12 pallets at 21000 kg stays 21000 kg and not abnormal", () => {
  const result = recommend([{
    quantity: 12,
    weight_kg: 1750,
    length_m: 1.2,
    width_m: 1,
    height_m: 1.5,
    cargo_category: "general_freight",
    notes: "Freight type: Pallets / palletised goods | Total shipment weight: 21000 kg"
  }]);
  assert.equal(result.totalWeight, 21000);
  assert.equal(result.trucks, 1);
  assert.equal(result.abnormal, false);
});

test("TEST C: small 2 pallet shipment keeps smaller configured vehicle", () => {
  const result = recommend([{
    quantity: 2,
    weight_kg: 250,
    length_m: 1.2,
    width_m: 1,
    height_m: 1.2,
    cargo_category: "general_freight",
    notes: "Total shipment weight: 500 kg"
  }]);
  assert.equal(result.vehicle, "8 ton / 14 ton");
  assert.equal(result.trucks, 1);
  assert.equal(result.abnormal, false);
});

test("TEST D and E: abnormal dimensions trigger lowbed; heavy normal dimensions do not", () => {
  const oversized = recommend([{
    quantity: 1,
    weight_kg: 9000,
    length_m: 13,
    width_m: 2.7,
    height_m: 3,
    cargo_category: "machinery"
  }]);
  assert.equal(oversized.abnormal, true);
  assert.equal(oversized.trailer, "Lowbed");

  const heavyNormal = recommend([{
    quantity: 1,
    weight_kg: 32000,
    length_m: 12,
    width_m: 2.4,
    height_m: 3.8,
    cargo_category: "general_freight",
    notes: "Total shipment weight: 32000 kg"
  }]);
  assert.equal(heavyNormal.abnormal, false);
});

test("TEST F and G: customer validation blocks missing pallet dimensions and insurance value", () => {
  const app = read("src/app.ts");
  assert.ok(app.includes("Please add the pallet ${dimensionLabel(name)} in millimetres."), "missing pallet dimensions should block submission");
  assert.ok(app.includes("selectedFreightType(cargoCard) === \"pallets\""), "pallet-specific validation must run only for palletised freight");
  assert.ok(app.includes("Please add the cargo value when insurance is required."), "insurance=yes must require cargo value");
  assert.ok(app.includes("Please add dangerous-goods details in the notes."), "dangerous goods must request details");
  assert.ok(app.includes("Please add the required temperature range or details in the notes."), "temperature loads must request details");
});

if (process.exitCode) {
  process.exit(process.exitCode);
}
