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

const equipmentProfiles = [
  { code: "bakkie-panel-1t", vehicle: "1-ton bakkie / panel van", trailer: "Closed body", payload: 1000, cube: 6, deck: 4.8, pallets: 2, specialist: false, refrigerated: false, openDeck: false, priority: 10 },
  { code: "rigid-4t-curtain", vehicle: "4-ton rigid curtainsider", trailer: "Curtain side body", payload: 4000, cube: 22, deck: 13.8, pallets: 8, specialist: false, refrigerated: false, openDeck: false, priority: 20 },
  { code: "rigid-8t-tautliner", vehicle: "8-ton rigid tautliner", trailer: "Tautliner", payload: 8000, cube: 45, deck: 17.64, pallets: 10, specialist: false, refrigerated: false, openDeck: false, priority: 30 },
  { code: "tri-axle-tautliner", vehicle: "Horse + tri-axle tautliner", trailer: "Tautliner", payload: 28000, cube: 85, deck: 33.48, pallets: 26, specialist: false, refrigerated: false, openDeck: false, priority: 40 },
  { code: "tri-axle-flatdeck", vehicle: "Horse + tri-axle flatdeck", trailer: "Flatdeck / tri-axle", payload: 28000, cube: 80, deck: 33.48, pallets: 24, specialist: false, refrigerated: false, openDeck: true, priority: 50 },
  { code: "superlink-tautliner", vehicle: "Superlink tautliner", trailer: "Superlink tautliner", payload: 34000, cube: 100, deck: 44.64, pallets: 34, specialist: false, refrigerated: false, openDeck: false, priority: 60 },
  { code: "reefer-trailer", vehicle: "Refrigerated reefer trailer", trailer: "Refrigerated trailer", payload: 31000, cube: 85, deck: 33.01, pallets: 24, specialist: false, refrigerated: true, openDeck: false, priority: 80 },
  { code: "lowbed-30t", vehicle: "30-ton lowbed", trailer: "Lowbed", payload: 29350, cube: 70, deck: 22.95, pallets: 0, specialist: true, refrigerated: false, openDeck: true, priority: 200 },
  { code: "heavy-haul-specialist", vehicle: "Heavy haul / abnormal specialist", trailer: "Specialist abnormal trailer", payload: 55000, cube: 70, deck: 54, pallets: 0, specialist: true, refrigerated: false, openDeck: true, priority: 300 }
];

function equipmentRecommend(items) {
  const totalWeight = items.reduce((sum, item) => sum + itemTotalWeightKg(item), 0);
  const totalVolume = items.reduce((sum, item) => sum + (item.quantity || 1) * (item.length_m || 0) * (item.width_m || 0) * (item.height_m || 0), 0);
  const totalDeckArea = items.reduce((sum, item) => sum + (item.quantity || 1) * (item.length_m || 0) * (item.width_m || 0), 0);
  const itemCount = items.reduce((sum, item) => sum + (item.quantity || 1), 0);
  const maxLength = Math.max(0, ...items.map((item) => item.length_m || 0));
  const maxWidth = Math.max(0, ...items.map((item) => item.width_m || 0));
  const maxHeight = Math.max(0, ...items.map((item) => item.height_m || 0));
  const machinery = items.some((item) => item.cargo_category === "machinery");
  const refrigerated = items.some((item) => item.temperature_controlled);
  const pallets = items.some((item) => String(item.notes ?? "").toLowerCase().includes("pallet"));
  const dimensionallyAbnormal = maxLength > 12 || maxWidth > 2.5 || maxHeight > 4.3;
  const candidates = equipmentProfiles
    .filter((profile) => !refrigerated || profile.refrigerated)
    .filter((profile) => dimensionallyAbnormal ? profile.specialist : !profile.specialist)
    .filter((profile) => !machinery || profile.openDeck || profile.specialist)
    .map((profile) => ({
      ...profile,
      units: Math.max(1, Math.ceil(Math.max(
        totalWeight / profile.payload,
        totalVolume / profile.cube,
        totalDeckArea / profile.deck,
        pallets && profile.pallets ? itemCount / profile.pallets : 1
      )))
    }))
    .sort((left, right) => left.units - right.units || left.priority - right.priority);
  return { totalWeight, profile: candidates[0], abnormal: dimensionallyAbnormal };
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

test("standard equipment engine migration is additive and exposes override pricing hooks", () => {
  const migration = read("supabase/migrations/20260810002000_standard_equipment_engine.sql");
  const overrideFix = read("supabase/migrations/20260810003000_fix_equipment_override_reset_and_utilization.sql");
  const resetFix = read("supabase/migrations/20260810004000_recompute_system_units_on_equipment_reset.sql");
  assert.ok(migration.includes("create table if not exists public.standard_equipment_profiles"), "standard equipment profiles table should be additive");
  assert.ok(migration.includes("system_equipment_profile_id"), "system equipment selection must be retained");
  assert.ok(migration.includes("final_equipment_profile_id"), "final/overridden equipment selection must be retained");
  assert.ok(migration.includes("equipment_alternatives"), "alternatives should be captured for manager review");
  assert.ok(migration.includes("estimated_deck_utilization_percent"), "deck utilisation should be captured");
  assert.ok(migration.includes("create or replace function public.ttaq_apply_equipment_override"), "Henning override RPC must exist");
  assert.ok(overrideFix.includes("equipment_override_history"), "override/reset history must be preserved");
  assert.ok(overrideFix.includes("system_number_of_trucks"), "system unit count must be retained for reset");
  assert.ok(overrideFix.includes("estimated_payload_utilization_percent = coalesce(payload_util, 0)"), "override must recalculate payload utilisation");
  assert.ok(resetFix.includes("case when coalesce(system_profile_record.typical_pallet_capacity"), "reset must recompute system units from cargo and equipment capacity");
  assert.ok(migration.includes("vehicle_dependent_costs_multiplier"), "pricing output must expose unit-count multiplier");
  assert.ok(migration.includes("equipment_price_generated"), "pricing audit event should record equipment pricing");
  assert.equal(migration.includes("or total_weight > 30000"), false, "mass-only abnormal rule must not return");
  assert.equal(migration.includes("or total_weight > 45000"), false, "mass-only escort rule must not return");
});

test("TEST H-L: equipment catalogue chooses sensible profiles without customer equipment input", () => {
  const palletLoad = equipmentRecommend([{
    quantity: 12,
    weight_kg: 1750,
    length_m: 1.2,
    width_m: 1,
    height_m: 1.5,
    cargo_category: "general_freight",
    notes: "Freight type: Pallets / palletised goods | Total shipment weight: 21000 kg"
  }]);
  assert.equal(palletLoad.totalWeight, 21000);
  assert.equal(palletLoad.profile.vehicle, "Horse + tri-axle tautliner");
  assert.equal(palletLoad.profile.units, 1);
  assert.equal(palletLoad.abnormal, false);

  const reeferLoad = equipmentRecommend([{
    quantity: 10,
    weight_kg: 1500,
    length_m: 1.2,
    width_m: 1,
    height_m: 1.4,
    cargo_category: "refrigerated",
    temperature_controlled: true,
    notes: "Total shipment weight: 15000 kg"
  }]);
  assert.equal(reeferLoad.profile.vehicle, "Refrigerated reefer trailer");

  const machineryLoad = equipmentRecommend([{
    quantity: 1,
    weight_kg: 14000,
    length_m: 8,
    width_m: 2.2,
    height_m: 3,
    cargo_category: "machinery"
  }]);
  assert.equal(machineryLoad.profile.trailer, "Flatdeck / tri-axle");
  assert.equal(machineryLoad.abnormal, false);

  const abnormalLoad = equipmentRecommend([{
    quantity: 1,
    weight_kg: 9000,
    length_m: 13,
    width_m: 2.7,
    height_m: 3,
    cargo_category: "machinery"
  }]);
  assert.equal(abnormalLoad.profile.trailer, "Lowbed");
  assert.equal(abnormalLoad.abnormal, true);
});

if (process.exitCode) {
  process.exit(process.exitCode);
}
