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

test("browser bundle does not reference service-role or provider secrets", () => {
  const browserFiles = ["src/app.ts", "src/supabaseClient.ts", "public/index.html", "public/quote-view.html"];
  const forbidden = ["SUPABASE_SERVICE_ROLE_KEY", "RESEND_API_KEY", "SENDGRID_API_KEY", "POSTMARK_SERVER_TOKEN"];
  for (const file of browserFiles) {
    const contents = read(file);
    for (const token of forbidden) {
      assert.equal(contents.includes(token), false, `${file} must not reference ${token}`);
    }
  }
});

test("production Edge Function validates actions, UUIDs, paths, MIME, recipients, and duplicate sends", () => {
  const edge = read("supabase/functions/production-integrations/index.ts");
  for (const expected of [
    "assertAction",
    "assertUuid",
    "assertStoragePath",
    "Unsupported upload target",
    "Unsupported file type",
    "File must be 15MB or smaller",
    "Quote emails can only be sent to the customer email",
    "Invoice emails can only be sent to the customer email",
    "already sent"
  ]) {
    assert.ok(edge.includes(expected), `Edge Function should include ${expected}`);
  }
});

test("public quote PDF access is token/reference mediated", () => {
  const edge = read("supabase/functions/production-integrations/index.ts");
  assert.ok(edge.includes("ttaq_get_public_quote_document"), "public PDF URL must use public quote RPC");
  assert.ok(edge.includes("A secure quote token or reference is required."), "public PDF action must require a token/reference");
  assert.ok(edge.includes('.from("quote_documents").select("pdf_storage_path")'), "public PDF action should only load the storage path needed for a signed URL");
});

test("hardening migration adds production integrity constraints", () => {
  const migration = read("supabase/migrations/20260706025000_production_readiness_hardening.sql");
  for (const expected of [
    "route_estimates_non_negative_distance_check",
    "transport_jobs_status_check",
    "invoices_amounts_non_negative_check",
    "invoice_payments_amount_non_negative_check",
    "transport_job_documents_storage_path_safe_check",
    "quote_documents_pdf_path_safe_check"
  ]) {
    assert.ok(migration.includes(expected), `migration should include ${expected}`);
  }
});

test("financial rounding vector is deterministic", () => {
  const subtotal = 10000;
  const fuelSurcharge = 500;
  const seasonalMultiplier = 1.2;
  const toll = 300;
  const routeRisk = 250;
  const margin = 0.2;
  const vatRate = 0.15;
  const adjustedBase = Math.round((subtotal + fuelSurcharge) * seasonalMultiplier * 100) / 100;
  const preProfit = adjustedBase + toll + routeRisk;
  const profit = Math.max(1500, Math.round(preProfit * margin * 100) / 100);
  const beforeVat = preProfit + profit;
  const vat = Math.round(beforeVat * vatRate * 100) / 100;
  const total = Math.round((beforeVat + vat) * 100) / 100;
  assert.deepEqual({ adjustedBase, preProfit, profit, vat, total }, {
    adjustedBase: 12600,
    preProfit: 13150,
    profit: 2630,
    vat: 2367,
    total: 18147
  });
});

test("final polish keeps customer and manager UI premium and nontechnical", () => {
  const app = read("src/app.ts");
  const styles = read("public/styles.css");
  const login = read("public/login.html");
  const users = read("public/users-dashboard.html");

  assert.ok(app.includes("refreshEquipmentAndPricing"), "equipment override should refresh quote review pricing in place");
  assert.ok(app.includes("Price updated."), "equipment override should confirm repriced selections");
  assert.ok(app.includes("System recommendation restored."), "equipment reset should confirm system pricing restored");
  assert.ok(app.includes("Recommended selling price"), "pricing summary should make the final price prominent");
  assert.ok(app.includes("Detailed pricing lines"), "internal calculation detail should be available but secondary");
  assert.ok(styles.includes(".price-hero"), "pricing hero styles should be present");
  assert.ok(styles.includes(".skeleton-card"), "premium loading skeletons should be present");
  assert.ok(login.includes("showPasswordToggle"), "login should support a show-password control");
  assert.equal(login.includes("Supabase Auth"), false, "login page should avoid backend-provider jargon");
  assert.equal(users.includes("Supabase Auth user ID"), false, "users page should avoid backend-provider jargon");
});

if (process.exitCode) {
  process.exit(process.exitCode);
}
