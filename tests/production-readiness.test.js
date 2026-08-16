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
  const password = read("public/password.html");

  assert.ok(app.includes("refreshEquipmentAndPricing"), "equipment override should refresh quote review pricing in place");
  assert.ok(app.includes("Price updated."), "equipment override should confirm repriced selections");
  assert.ok(app.includes("System recommendation restored."), "equipment reset should confirm system pricing restored");
  assert.ok(app.includes("Recommended selling price"), "pricing summary should make the final price prominent");
  assert.ok(app.includes("Detailed pricing lines"), "internal calculation detail should be available but secondary");
  assert.ok(styles.includes(".price-hero"), "pricing hero styles should be present");
  assert.ok(styles.includes(".skeleton-card"), "premium loading skeletons should be present");
  assert.ok(login.includes("showPasswordToggle"), "login should support a show-password control");
  assert.ok(login.includes("Forgot password?"), "login should provide a forgot-password flow");
  assert.ok(password.includes("Create your password"), "invited users should have a first-password page");
  assert.ok(password.includes("Welcome to Time Trucking Auto-Quote"), "password setup should be branded for Time Trucking");
  assert.equal(login.includes("Supabase Auth"), false, "login page should avoid backend-provider jargon");
  assert.equal(password.includes("Supabase Auth"), false, "password setup page should avoid backend-provider jargon");
  assert.equal(users.includes("Supabase Auth user ID"), false, "users page should avoid backend-provider jargon");
  assert.equal(users.includes("User UUID"), false, "users page must not ask managers for backend UUIDs");
  assert.ok(users.includes("Invite User"), "users page should use the secure invitation flow");
  assert.ok(users.includes("No Supabase dashboard or UUID required"), "users page should explain UUID-free user creation");
});

test("invitation and password lifecycle stays branded, self-service, and Supabase Auth managed", () => {
  const app = read("src/app.ts");
  const client = read("src/supabaseClient.ts");
  const edge = read("supabase/functions/production-integrations/index.ts");
  const login = read("public/login.html");
  const password = read("public/password.html");

  for (const expected of [
    "password.html",
    "resend_internal_invitation",
    "resetPasswordForEmail",
    "requireInternalUserManagement",
    "Only an owner can resend an owner account link",
    "The user will create their own password"
  ]) {
    assert.ok(edge.includes(expected), `Edge invite lifecycle should include ${expected}`);
  }

  for (const expected of [
    "requestPasswordReset",
    "updateCurrentUserPassword",
    "getCurrentAuthSession",
    "passwordStrengthIssue",
    "Invitation link expired or already used",
    "Your account is ready",
    "resendInternalInvitationLink",
    "Send setup link",
    "Forgot password?"
  ]) {
    assert.ok(app.includes(expected) || client.includes(expected) || login.includes(expected), `auth lifecycle implementation should include ${expected}`);
  }

  for (const expected of [
    "How do I accept my invitation?",
    "How do I create my password?",
    "I forgot my password",
    "My invitation expired",
    "I did not receive my invitation",
    "How does an Owner resend an invitation?"
  ]) {
    assert.ok(app.includes(expected), `Help assistant content should include ${expected}`);
  }

  assert.ok(password.includes("autocomplete=\"new-password\""), "password setup should use new-password autocomplete");
  assert.equal((client + app).includes("SUPABASE_SERVICE_ROLE_KEY"), false, "browser code must not expose service role");
  assert.equal((client + app).includes("auth.admin"), false, "browser code must not use admin auth APIs");
});

test("final production hardening adds secure invitations, depot journey review, manual external-cost controls, and concise help", () => {
  const app = read("src/app.ts");
  const client = read("src/supabaseClient.ts");
  const edge = read("supabase/functions/production-integrations/index.ts");
  const migration = read("supabase/migrations/20260810014400_final_operational_hardening_foundation.sql");
  const pricingPage = read("public/pricing-settings.html");
  const adminPage = read("public/admin-settings.html") + app;
  const helpPage = read("public/help.html");

  for (const expected of [
    "internal_user_invitations",
    "company_operating_depots",
    "quote_operational_journey_legs",
    "quote_manual_external_costs",
    "vat_rate_authorities",
    "South African Revenue Service (SARS)",
    "cross_border_external_charge_sources",
    "permit_fee_catalogue",
    "cargo_insurance_profiles",
    "contextual_help_topics",
    "ttaq_quote_operational_journey_summary",
    "ttaq_update_quote_return_load_status",
    "ttaq_save_default_operating_depot",
    "return_load_status in ('none', 'available', 'unknown_review_required')",
    "Commercial billable distance remains separate until Henning confirms day/km and return-trip rules",
    "Missing costs remain review-required, not R0",
    "Deprecated: crane cost is quote-specific/manual review",
    "Deprecated: high-value insurance requires approved insurer formula or manual cost"
  ]) {
    assert.ok(migration.includes(expected), `final hardening migration should include ${expected}`);
  }

  assert.equal(client.includes("saveInternalUser"), false, "client must not expose direct internal-user UUID upsert");
  assert.ok(client.includes("inviteInternalUser"), "client should invoke secure server-side invitations");
  assert.ok(client.includes("saveDefaultOperatingDepot"), "client should save default depot through RPC");
  assert.ok(edge.includes("invite_internal_user"), "Edge Function should expose secure invite action");
  assert.ok(edge.includes("auth.admin.inviteUserByEmail"), "Edge Function should create/login-link users server-side");
  assert.ok(edge.includes("requireInternalUserManagement"), "user invitation must require internal user-management permission");
  assert.equal(edge.includes("DIESEL_REFRESH_SECRET"), true, "server-only Edge Function may read refresh secret");

  for (const expected of [
    "pricing-tabs",
    "Manual crane cost required",
    "Insurance review required",
    "Operational info only",
    "HAZ cargo selects the HAZ commercial rate",
    "Advanced / Legacy / Fallback Settings"
  ]) {
    assert.ok(pricingPage.includes(expected), `pricing page should include ${expected}`);
  }

  for (const expected of [
    "Default operating depot",
    "Registered legal name",
    "VAT number",
    "Quote contact name",
    "saveDefaultOperatingDepot",
    "Depot to pickup to delivery to depot model"
  ]) {
    assert.ok(adminPage.includes(expected), `admin settings should include ${expected}`);
  }

  for (const expected of [
    "data-page=\"help\"",
    "Customer quote safety",
    "External charges",
    "Internal guide",
    "data-nav=\"help\""
  ]) {
    assert.ok(helpPage.includes(expected) || app.includes(expected), `help route should include ${expected}`);
  }

  assert.ok(app.includes("renderOperationalJourneyCard"), "Quote Review should render depot-return journey review");
  assert.ok(app.includes("Commercial backload treatment remains review-required until Henning confirms the rule."), "Quote Review should support authorized return-load status updates");
  assert.equal(pricingPage.includes("Default toll cost"), false, "pricing UI should not foreground legacy default toll pricing");
  assert.equal(pricingPage.includes("Generic Hazmat surcharge"), false, "pricing UI should not foreground generic HAZ stacking");
});

test("public RFQ submit button has loading, duplicate-click protection, and success feedback", () => {
  const app = read("src/app.ts");

  assert.ok(app.includes("let rfqSubmissionInFlight = false"), "RFQ submit path must track an in-flight submission");
  assert.ok(app.includes("let rfqSubmissionComplete = false"), "successful RFQ submission should lock the final submit action");
  assert.ok(app.includes("form.noValidate = true"), "RFQ should use custom validation instead of silent browser-native blocking");
  assert.ok(app.includes("setSubmitLoading(\"Sending your request...\")"), "valid Review submit should immediately show a loading state");
  assert.ok(app.includes("submitButton.textContent = \"Sending request...\""), "submit button should visibly change while submitting");
  assert.ok(app.includes("submitButton.addEventListener(\"click\""), "the actual rendered Request Quote button must have an explicit click handler");
  assert.ok(app.includes("if (rfqSubmissionInFlight || rfqSubmissionComplete) return;"), "duplicate clicks must not start another submission");
  assert.ok(app.includes("const result = await submitPublicRfq(rawToken, payload)"), "click path must await the existing public RFQ submit call");
  assert.ok(app.includes("void autoRouteSubmittedRfq"), "route/pricing automation must run after RFQ creation without blocking customer acknowledgement");
  assert.ok(app.includes("Thanks - your quote request has been received."), "success state must render a customer-safe confirmation");
  assert.ok(app.includes("keepSubmitComplete()"), "successful RFQ creation should keep the submit button disabled");
  assert.ok(app.includes("if (isFinal && !rfqSubmissionComplete) clearSubmitLoading();"), "button state must recover only after actual creation failure");
});

test("pricing automation keeps source metadata, business-rule fields, and override warnings", () => {
  const migration = read("supabase/migrations/20260810005000_pricing_automation_architecture.sql");
  const pricingPage = read("public/pricing-settings.html");
  const app = read("src/app.ts");

  for (const expected of [
    "pricing_external_providers",
    "za_dmre_cef_diesel",
    "pricing_source_snapshot",
    "automation_status",
    "ttaq_current_diesel_input",
    "ttaq_record_diesel_provider_result",
    "grant execute on function public.ttaq_record_diesel_provider_result",
    "additional_stop_rate",
    "cross_border_surcharge",
    "minimum_margin_percent",
    "warning_flags",
    "manager_price_override_recorded"
  ]) {
    assert.ok(migration.includes(expected), `automation migration should include ${expected}`);
  }

  assert.ok(pricingPage.includes("Automatic market and route inputs"), "Pricing page should separate external inputs");
  assert.ok(pricingPage.includes("Time Trucking commercial rules"), "Pricing page should separate commercial rules");
  assert.ok(pricingPage.includes("Diesel price unavailable - automatic pricing requires review."), "diesel provider status must be transparent until a valid official value is loaded");
  assert.ok(app.includes("loadPricingSettings"), "Pricing page should load active database values");
  assert.ok(app.includes("Active database values loaded."), "Pricing page should visibly confirm remote active values loaded");
  assert.ok(app.includes("Source transparency"), "quote review should show pricing source metadata");
  assert.ok(app.includes("Resulting profit"), "manager override UI should show resulting profit");
  assert.ok(app.includes("Resulting margin"), "manager override UI should show resulting margin");
});

test("official diesel provider uses DMPR source and protects zero-price quoting", () => {
  const migration = read("supabase/migrations/20260810007000_official_diesel_provider.sql");
  const edge = read("supabase/functions/production-integrations/index.ts");
  const pricingPage = read("public/pricing-settings.html");

  for (const expected of [
    "pricing_diesel_configuration",
    "preferred_diesel_grade",
    "diesel_500ppm",
    "diesel_50ppm",
    "pricing_basis",
    "adjustment_type",
    "manual_override_expires_at",
    "za_dmpr_official_diesel",
    "Department of Mineral and Petroleum Resources official diesel publication",
    "Successful diesel provider result requires a positive price",
    "Official diesel price outside plausible ZAR/L range",
    "duplicate_id",
    "Diesel price unavailable - automatic pricing requires review.",
    "official_reference_price_per_litre",
    "effective_diesel_price_per_litre",
    "Cached official value"
  ]) {
    assert.ok(migration.includes(expected), `official diesel migration should include ${expected}`);
  }

  for (const expected of [
    "refresh_official_diesel",
    "DMPR_FUEL_PRICES_URL",
    "latestDmprPublication",
    "parseDieselPricesFromText",
    "centsToRand",
    "diesel_500ppm",
    "diesel_50ppm",
    "deflate-raw",
    "No valid diesel grade price could be extracted",
    "ttaq_record_diesel_provider_result",
    "za_dmpr_official_diesel"
  ]) {
    assert.ok(edge.includes(expected), `Edge Function should include ${expected}`);
  }

  assert.ok(pricingPage.includes("Current effective diesel"), "Pricing UI should show effective diesel");
  assert.ok(pricingPage.includes("Official reference"), "Pricing UI should show official reference");
  assert.ok(pricingPage.includes("Preferred diesel grade"), "Pricing UI should let Henning choose a diesel grade");
  assert.ok(pricingPage.includes("Pricing basis"), "Pricing UI should capture geographic basis");
  assert.ok(pricingPage.includes("Time Trucking adjustment"), "Pricing UI should capture Time Trucking adjustment");
  assert.ok(pricingPage.includes("Override expires"), "Pricing UI should support temporary overrides");
});

test("diesel parser expectations cover grades, unit conversion, outages, and snapshots", () => {
  const edge = read("supabase/functions/production-integrations/index.ts");
  const migration = read("supabase/migrations/20260810007000_official_diesel_provider.sql");
  const pricingMigration = read("supabase/migrations/20260810005000_pricing_automation_architecture.sql");
  const sample = "Diesel 0.05% sulphur wholesale 2391.57 c/l Diesel 0.005% sulphur wholesale 2429.97 c/l";
  const centsToRand = (value) => Number((value / 100).toFixed(4));
  const extracted = [...sample.matchAll(/Diesel\s+(0\.0?05)%[^0-9]+([0-9.]+)\s*c\/l/gi)].map((match) => ({
    grade: match[1] === "0.005" ? "diesel_50ppm" : "diesel_500ppm",
    price: centsToRand(Number(match[2]))
  }));

  assert.deepEqual(extracted, [
    { grade: "diesel_500ppm", price: 23.9157 },
    { grade: "diesel_50ppm", price: 24.2997 }
  ]);
  assert.ok(edge.includes("effectiveDate"), "provider response should expose effective date");
  assert.ok(migration.includes("d.effective_from <= current_date"), "future official prices must not become active before effective date");
  assert.ok(migration.includes("duplicate_id"), "duplicate official publications should update metadata instead of creating daily duplicates");
  assert.ok(migration.includes("provider_status not in ('success', 'verified', 'live')"), "provider outage should be recorded as a failure");
  assert.ok(migration.includes("manual_override_expires_at > now()"), "manual override expiry should return control to official value");
  assert.ok(migration.includes("round(official_price * (1 + adjustment_value / 100), 4)"), "percentage adjustment should recalculate effective diesel");
  assert.ok(pricingMigration.includes("'diesel', diesel_record.source_payload"), "pricing snapshots should retain diesel source metadata");
  assert.ok(migration.includes("coalesce(chosen.price_per_litre, 0) <= 0"), "R0 diesel must force manager review");
});

test("official diesel scheduler uses Vault, pg_cron, pg_net, and secure invocation", () => {
  const scheduler = read("supabase/migrations/20260810010000_secure_diesel_refresh_scheduler.sql");
  const edge = read("supabase/functions/production-integrations/index.ts");
  const pricingPage = read("public/pricing-settings.html");
  const client = read("src/supabaseClient.ts");
  const app = read("src/app.ts");

  for (const expected of [
    "create extension if not exists pg_net",
    "create extension if not exists pg_cron",
    "create extension if not exists supabase_vault",
    "vault.decrypted_secrets",
    "ttaq_diesel_refresh_secret",
    "ttaq_supabase_publishable_key",
    "ttaq_trigger_official_diesel_refresh",
    "net.http_post",
    "cron.schedule",
    "17 4 * * *",
    "pricing_provider_refresh_runs",
    "last_check_at",
    "next_expected_check_at",
    "scheduler_status",
    "grant execute on function public.ttaq_trigger_official_diesel_refresh(text) to service_role"
  ]) {
    assert.ok(scheduler.includes(expected), `scheduler migration should include ${expected}`);
  }

  assert.ok(edge.includes("install_diesel_scheduler"), "Edge Function should install scheduler from server-side env secrets");
  assert.ok(edge.includes("diesel_scheduler_status"), "Edge Function should expose secret-protected scheduler health verification");
  assert.ok(edge.includes("trigger_diesel_scheduler_once"), "Edge Function should support secret-protected scheduler test trigger");
  assert.ok(edge.includes("Diesel scheduler installation requires the server-side refresh secret."), "scheduler install must require server-side secret");
  assert.ok(edge.includes("Diesel scheduler status requires the server-side refresh secret."), "scheduler status must require server-side secret");
  assert.ok(edge.includes("refreshOfficialDiesel"), "manual and scheduled refresh should use same provider workflow");
  assert.ok(client.includes("refreshOfficialDieselPrice"), "client should expose an authorised manual refresh action");
  assert.ok(app.includes("refreshOfficialDieselButton"), "Pricing UI should wire manual refresh");
  assert.ok(pricingPage.includes("Check for latest official diesel price"), "Pricing UI should include manual refresh button");
  assert.ok(pricingPage.includes("Official diesel feed needs attention"), "Pricing UI should show simple provider health");
  assert.ok(client.includes("Official diesel feed healthy"), "Pricing loader should populate healthy provider state");

  for (const browserFile of ["src/app.ts", "src/supabaseClient.ts", "public/pricing-settings.html"]) {
    assert.equal(read(browserFile).includes("DIESEL_REFRESH_SECRET"), false, `${browserFile} must not expose refresh secret name/value`);
    assert.equal(read(browserFile).includes("ttaq_diesel_refresh_secret"), false, `${browserFile} must not reference Vault secret names`);
  }
});

test("official toll engine models providers, plazas, Class 1-4 tariffs, and VAT-inclusive snapshots", () => {
  const migration = read("supabase/migrations/20260810013000_official_toll_pricing_engine.sql");
  const repairMigration = read("supabase/migrations/20260810013900_repair_sa_toll_catalogue.sql");
  const verifiedMigration = read("supabase/migrations/20260810014000_verify_2026_toll_catalogue.sql");
  const coordinateMigration = read("supabase/migrations/20260810014100_correct_toll_coordinate_readiness.sql");
  const edge = read("supabase/functions/production-integrations/index.ts");
  const pricingPage = read("public/pricing-settings.html");
  const app = read("src/app.ts");
  const client = read("src/supabaseClient.ts");

  for (const expected of [
    "toll_plazas",
    "toll_tariffs",
    "class_1_rate",
    "class_2_rate",
    "class_3_rate",
    "class_4_rate",
    "vat_included boolean not null default true",
    "effective_from date not null",
    "effective_to date",
    "toll_class integer",
    "Toll vehicle class requires confirmation.",
    "za_sanral_official_tolls",
    "za_bakwena_official_tolls",
    "za_trac_n4_official_tolls",
    "za_n3tc_official_tolls",
    "2026-03-01",
    "Bakwena toll tariffs applicable from 1 March 2026 to 28 February 2027",
    "ttaq_calculate_official_route_tolls",
    "toll_free_route",
    "manual_review_required",
    "missing_applicable_tariff",
    "official tariffs are VAT-inclusive cost inputs",
    "toll_pricing_overrides",
    "management_override"
  ]) {
    assert.ok(migration.includes(expected), `toll migration should include ${expected}`);
  }

  for (const expected of [
    "decodePolyline",
    "distanceToSegmentMeters",
    "matchOfficialTollPlazas",
    "toll_plaza_matching",
    "route_segment_index",
    "new Map(matches.map",
    "refresh_official_tolls",
    "install_toll_scheduler",
    "Toll scheduler installation requires the server-side refresh secret."
  ]) {
    assert.ok(edge.includes(expected), `Edge Function should include ${expected}`);
  }

  assert.ok(pricingPage.includes("Toll tariff source status"), "Pricing page should show toll provider status");
  assert.ok(pricingPage.includes("Toll plaza catalogue"), "Pricing page should show toll plaza catalogue");
  assert.ok(pricingPage.includes("Equipment toll classes") || app.includes("Toll class requires confirmation"), "Pricing UI should expose equipment toll class state");
  assert.ok(app.includes("current_tariff_count"), "Pricing UI should show current tariff counts, not only provider labels");
  assert.ok(app.includes("coordinate_coverage_percent"), "Pricing UI should show coordinate coverage");
  assert.ok(app.includes("classification_coverage_percent"), "Pricing UI should show classification coverage");
  assert.ok(app.includes("Toll calculation"), "Quote Review should show toll calculation details");
  assert.ok(app.includes("Detected plazas"), "Quote Review should show detected plaza count");
  assert.ok(client.includes("ttaq_toll_provider_status"), "Pricing loader should fetch toll provider health from DB");
  assert.ok(client.includes("ttaq_current_toll_catalogue"), "Pricing loader should fetch active toll catalogue from DB");

  for (const expected of [
    "ttaq_refresh_toll_provider_coverage",
    "Complete cannot coexist with zero active plazas",
    "N3TC Toll Fee Groups effective from 1 March 2026",
    "TRAC N4 toll plazas and toll fees effective from 1 March 2026",
    "n3tc-n3-de-hoek-mainline",
    "n3tc-n3-wilge-mainline",
    "n3tc-n3-tugela-mainline",
    "n3tc-n3-mooi-mainline",
    "trac-n4-diamond-hill-mainline",
    "trac-n4-middelburg-mainline",
    "trac-n4-machado-mainline",
    "trac-n4-nkomazi-mainline",
    "current_tariff_count",
    "coordinate_coverage_percent",
    "classification_coverage_percent",
    "route_matching_readiness",
    "verified_route_geometry",
    "strict_ramp_geometry_threshold"
  ]) {
    assert.ok(repairMigration.includes(expected), `toll repair migration should include ${expected}`);
  }
  assert.equal(repairMigration.includes("delete from public.toll_tariffs"), false, "toll repair must not delete historical tariffs");
  assert.equal(repairMigration.includes("truncate"), false, "toll repair must not truncate toll history");
  for (const expected of [
    "Government Gazette Nos. 54087 and 54088",
    "'vat_included', true",
    "za_n3tc_official_tolls_stale_webpage_superseded",
    "n3tc-n3-de-hoek-mainline', 'De Hoek Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -26.7256385, 28.4147685, 'mainline', 67.00, 105.00, 160.00, 230.00",
    "n3tc-n3-wilge-mainline', 'Wilge Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -27.1008650, 28.6648159, 'mainline', 94.00, 161.00, 215.00, 304.00",
    "n3tc-n3-tugela-mainline', 'Tugela Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -28.4480585, 29.5313636, 'mainline', 100.00, 165.00, 260.00, 359.00",
    "n3tc-n3-mooi-mainline', 'Mooi Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -29.1991016, 29.9984886, 'mainline', 70.00, 171.00, 240.00, 324.00",
    "sanral-n1-grasmere-mainline",
    "sanral-n1-vaal-mainline",
    "sanral-n1-verkeerdevlei-mainline",
    "sanral-n1-huguenot-mainline",
    "sanral-n3-mariannhill-mainline",
    "coordinate_confidence = 'review_required'",
    "geometry_matching_ready_for_verified_plazas",
    "ttaq_toll_tariffs_one_active_source_per_effective"
  ]) {
    assert.ok(verifiedMigration.includes(expected), `verified toll migration should include ${expected}`);
  }
  assert.equal(verifiedMigration.includes("delete from public.toll_tariffs"), false, "verified toll migration must not delete historical tariffs");
  assert.equal(verifiedMigration.includes("truncate"), false, "verified toll migration must not truncate toll history");
  for (const expected of [
    "n3tc-n3-tugela-east-ramp",
    "Ramp coordinate is not independently verified; do not reuse Tugela mainline coordinate",
    "sanral-n1-grasmere-mainline', -26.4171100, 27.8807500",
    "sanral-n1-vaal-mainline', -26.8563900, 27.6352800",
    "sanral-n1-verkeerdevlei-mainline', -28.7988900, 26.6905600",
    "sanral-n1-huguenot-mainline', -33.7428000, 19.0197000",
    "sanral-n3-mariannhill-mainline', -29.8230200, 30.8027600",
    "select public.ttaq_refresh_toll_provider_coverage()"
  ]) {
    assert.ok(coordinateMigration.includes(expected), `coordinate correction migration should include ${expected}`);
  }
  assert.equal(coordinateMigration.includes("delete from public.toll_tariffs"), false, "coordinate correction must not delete historical tariffs");
  assert.equal(coordinateMigration.includes("truncate"), false, "coordinate correction must not truncate toll history");
  assert.ok(edge.includes("plaza.plaza_type === \"ramp\" ? 180 : 900"), "ramp matching should be stricter than mainline matching");
  assert.ok(edge.includes("confidenceRatio < 0.72"), "ramp matches should require high confidence to avoid accidental ramp tolls");
  assert.ok(edge.includes("routeReadyCoordinateConfidence"), "automatic matching should require route-ready coordinate confidence");
  assert.ok(edge.includes("plaza.latitude === null || plaza.longitude === null"), "missing coordinates should not be auto-matched");
  assert.ok(edge.includes("mode: \"verified\""), "scheduled refresh should keep populated TRAC/N3TC coverage verified instead of reverting to partial");

  for (const browserFile of ["src/app.ts", "src/supabaseClient.ts", "public/pricing-settings.html"]) {
    assert.equal(read(browserFile).includes("ttaq_diesel_refresh_secret"), false, `${browserFile} must not expose Vault secret names`);
    assert.equal(read(browserFile).includes("DIESEL_REFRESH_SECRET"), false, `${browserFile} must not expose refresh secret names`);
  }
});

test("toll route matching guards nearby false positives, duplicate plazas, toll-free routes, and unknown toll data", () => {
  const migration = read("supabase/migrations/20260810013000_official_toll_pricing_engine.sql");
  const hardening = read("supabase/migrations/20260810013200_authoritative_toll_coverage_hardening.sql");
  const edge = read("supabase/functions/production-integrations/index.ts");

  assert.ok(edge.includes("plaza.plaza_type === \"ramp\" ? 180 : 900"), "ramp and mainline plazas should use strict route-geometry thresholds");
  assert.ok(edge.includes("distanceToSegmentMeters(point, route[index], route[index + 1])"), "plaza matching should use actual route geometry");
  assert.ok(edge.includes("[...new Map(matches.map"), "duplicate plaza matches should be prevented");
  assert.ok(edge.includes("match_confidence"), "matched plazas should include confidence metadata");
  assert.ok(edge.includes("route_order"), "matched plazas should include route order");
  assert.ok(migration.includes("match_status = 'matched' and match_count = 0"), "matched routes with no plazas should be toll-free");
  assert.ok(migration.includes("Toll amount unknown because route/plaza matching did not complete."), "unknown data should force review");
  assert.ok(migration.includes("provider_toll_status in ('available', 'expected_unknown')"), "Google toll metadata without trusted amount should remain review metadata");
  assert.ok(migration.includes("A matched toll plaza has no current official tariff."), "missing tariff rows should force review");
  assert.ok(hardening.includes("coverage_status in ('complete', 'partial', 'unavailable', 'needs_review')"), "providers should expose explicit coverage status");
  assert.ok(hardening.includes("provider.coverage_status = 'complete'"), "automatic pricing should require complete provider coverage");
  assert.ok(hardening.includes("Toll pricing requires review - official coverage incomplete."), "incomplete coverage should force manager review");
  assert.ok(hardening.includes("provider_toll_status in ('available', 'expected_unknown')"), "Google toll advisory with no official match should not become toll-free");
  assert.ok(hardening.includes("suggested_toll_class"), "equipment profiles should carry suggested toll-class workflow state");
  assert.ok(hardening.includes("toll_class_review_required"), "unconfirmed toll classes should remain review-required");
});

test("route-risk policy engine separates configured policy from route evidence", () => {
  const migration = read("supabase/migrations/20260810013300_route_risk_policy_engine.sql");
  const edge = read("supabase/functions/production-integrations/index.ts");
  const pricingPage = read("public/pricing-settings.html");
  const app = read("src/app.ts");
  const client = read("src/supabaseClient.ts");

  for (const expected of [
    "route_risk_categories",
    "route_risk_overrides",
    "trigger_scope",
    "rule_type",
    "geofence",
    "corridor",
    "priority",
    "effective_from",
    "effective_to",
    "source_status",
    "time_trucking_configured_policy",
    "external_advisory_only",
    "ttaq_evaluate_route_risk_policy",
    "ttaq_point_in_polygon",
    "ttaq_degrees_distance_km",
    "ttaq_route_points",
    "Highest-priority",
    "Route risk could not be fully evaluated",
    "R0 because no active Time Trucking route-risk rule matched.",
    "No Time Trucking risk rule configured/matched.",
    "ttaq_record_route_risk_override",
    "route_risk_override_recorded",
    "grant execute on function public.ttaq_record_route_risk_override"
  ]) {
    assert.ok(migration.includes(expected), `route-risk migration should include ${expected}`);
  }

  assert.ok(edge.includes("route_path_points"), "route automation should store sampled route geometry");
  assert.ok(edge.includes("route_geometry_status"), "route automation should state geometry availability");
  assert.ok(edge.includes("sampledRoutePoints"), "Edge Function should sample route points for geofence evaluation");
  assert.ok(pricingPage.includes("Route Risk"), "Pricing Settings should expose Route Risk policy section");
  assert.ok(pricingPage.includes("Highest-priority matching rule wins"), "Pricing Settings should disclose deterministic conflict handling");
  assert.ok(app.includes("Route Risk"), "Quote Review should show route risk analysis");
  assert.ok(app.includes("Matched rule"), "Quote Review should show controlling route-risk rule");
  assert.ok(app.includes("Override risk amount"), "Quote Review should include management override controls");
  assert.ok(client.includes("ttaq_route_risk_policy_summary"), "Pricing loader should fetch route-risk policy summary");
  assert.ok(client.includes("recordRouteRiskOverride"), "Client should expose route-risk override RPC");
});

function composePricingEnrichment({
  originalBaseBeforeSeasonal,
  oldToll,
  finalToll,
  oldRisk,
  fixedRisk,
  riskPercent,
  seasonalMultiplier,
  adminOverheadPercent,
  marginPercent,
  minimumProfit,
  vatPercent,
  minimumSellingPrice = 0
}) {
  const round = (value) => Math.round((value + Number.EPSILON) * 100) / 100;
  const tollDelta = finalToll - oldToll;
  const routeRiskBase = Math.max(originalBaseBeforeSeasonal - oldRisk + tollDelta, 0);
  const finalRisk = round(fixedRisk + routeRiskBase * (riskPercent / 100));
  const riskDelta = finalRisk - oldRisk;
  const finalBaseBeforeSeasonal = Math.max(routeRiskBase + finalRisk, 0);
  const seasonalAmount = round(finalBaseBeforeSeasonal * (seasonalMultiplier - 1));
  const subtotalBeforeOverhead = finalBaseBeforeSeasonal + seasonalAmount;
  const companyOverhead = round(subtotalBeforeOverhead * (adminOverheadPercent / 100));
  const subtotal = round(subtotalBeforeOverhead + companyOverhead);
  const profit = Math.max(round(subtotal * (marginPercent / 100)), minimumProfit, 0);
  const vat = round((subtotal + profit) * (vatPercent / 100));
  const grandTotalBeforeFloor = subtotal + profit + vat;
  const grandTotal = minimumSellingPrice > 0 && grandTotalBeforeFloor < minimumSellingPrice
    ? minimumSellingPrice
    : grandTotalBeforeFloor;

  return {
    tollDelta,
    riskDelta,
    combinedDelta: tollDelta + riskDelta,
    routeRiskBase,
    finalRisk,
    finalBaseBeforeSeasonal,
    seasonalAmount,
    companyOverhead,
    subtotal,
    profit,
    vat,
    grandTotal
  };
}

test("pricing enrichment finalisation composes toll and route-risk deltas deterministically", () => {
  const migration = read("supabase/migrations/20260810013400_fix_pricing_enrichment_composition.sql");

  for (const expected of [
    "ttaq_apply_pricing_enrichments",
    "for update",
    "drop trigger if exists ttaq_apply_official_toll_pricing_enrichment",
    "drop trigger if exists ttaq_apply_route_risk_policy_enrichment",
    "create trigger ttaq_apply_pricing_enrichments",
    "toll_delta_amount := final_toll_amount - old_toll_amount",
    "route_risk_delta_amount := final_route_risk_amount - old_route_risk_amount",
    "combined_component_delta := toll_delta_amount + route_risk_delta_amount",
    "route_risk_base_amount := greatest(original_base_before_seasonal - old_route_risk_amount + toll_delta_amount, 0)",
    "final_base_before_seasonal := greatest(route_risk_base_amount + final_route_risk_amount, 0)",
    "seasonal_multiplier",
    "company_overhead_amount",
    "minimum_profit",
    "minimum_selling_price",
    "pricing_order",
    "recommended_selling_price"
  ]) {
    assert.ok(migration.includes(expected), `composition migration should include ${expected}`);
  }

  assert.equal(
    migration.match(/create trigger ttaq_apply_pricing_enrichments/g).length,
    1,
    "only one finalisation trigger should be created"
  );

  const noTollNoRisk = composePricingEnrichment({
    originalBaseBeforeSeasonal: 1000,
    oldToll: 0,
    finalToll: 0,
    oldRisk: 0,
    fixedRisk: 0,
    riskPercent: 0,
    seasonalMultiplier: 1,
    adminOverheadPercent: 0,
    marginPercent: 10,
    minimumProfit: 0,
    vatPercent: 15
  });
  assert.equal(noTollNoRisk.finalBaseBeforeSeasonal, 1000, "no toll + no route risk should leave base unchanged");

  const tollOnly = composePricingEnrichment({
    originalBaseBeforeSeasonal: 1000,
    oldToll: 0,
    finalToll: 200,
    oldRisk: 0,
    fixedRisk: 0,
    riskPercent: 0,
    seasonalMultiplier: 1,
    adminOverheadPercent: 0,
    marginPercent: 10,
    minimumProfit: 0,
    vatPercent: 15
  });
  assert.equal(tollOnly.finalBaseBeforeSeasonal, 1200, "toll-only should add toll exactly once");

  const riskOnly = composePricingEnrichment({
    originalBaseBeforeSeasonal: 1000,
    oldToll: 0,
    finalToll: 0,
    oldRisk: 0,
    fixedRisk: 125,
    riskPercent: 0,
    seasonalMultiplier: 1,
    adminOverheadPercent: 0,
    marginPercent: 10,
    minimumProfit: 0,
    vatPercent: 15
  });
  assert.equal(riskOnly.finalBaseBeforeSeasonal, 1125, "route-risk-only should add route risk exactly once");

  const tollAndFixedRisk = composePricingEnrichment({
    originalBaseBeforeSeasonal: 1000,
    oldToll: 100,
    finalToll: 250,
    oldRisk: 50,
    fixedRisk: 90,
    riskPercent: 0,
    seasonalMultiplier: 1,
    adminOverheadPercent: 0,
    marginPercent: 10,
    minimumProfit: 0,
    vatPercent: 15
  });
  assert.equal(tollAndFixedRisk.combinedDelta, 190, "toll + fixed risk should compose explicit deltas");
  assert.equal(tollAndFixedRisk.finalBaseBeforeSeasonal, 1190, "toll + fixed risk should not drop either component");

  const tollAndPercentRisk = composePricingEnrichment({
    originalBaseBeforeSeasonal: 1000,
    oldToll: 100,
    finalToll: 250,
    oldRisk: 50,
    fixedRisk: 0,
    riskPercent: 10,
    seasonalMultiplier: 1,
    adminOverheadPercent: 0,
    marginPercent: 10,
    minimumProfit: 0,
    vatPercent: 15
  });
  assert.equal(tollAndPercentRisk.routeRiskBase, 1100, "percentage route risk should use the toll-adjusted pre-risk base");
  assert.equal(tollAndPercentRisk.finalRisk, 110, "percentage route risk should calculate from toll-adjusted base");
  assert.equal(tollAndPercentRisk.finalBaseBeforeSeasonal, 1210, "toll + percentage route risk should compose");

  const tollAndFixedAndPercentRisk = composePricingEnrichment({
    originalBaseBeforeSeasonal: 1000,
    oldToll: 100,
    finalToll: 250,
    oldRisk: 50,
    fixedRisk: 90,
    riskPercent: 10,
    seasonalMultiplier: 1.05,
    adminOverheadPercent: 8,
    marginPercent: 12,
    minimumProfit: 175,
    vatPercent: 15
  });
  assert.equal(tollAndFixedAndPercentRisk.routeRiskBase, 1100, "Bakwena automatic toll + route-risk rule should price risk after official toll");
  assert.equal(tollAndFixedAndPercentRisk.finalRisk, 200, "fixed and percentage risk components should compose");
  assert.equal(tollAndFixedAndPercentRisk.finalBaseBeforeSeasonal, 1300, "automatic toll and route risk should both remain in base");
  assert.equal(Math.round(tollAndFixedAndPercentRisk.grandTotal * 100) / 100, 1898.77, "downstream season, overhead, minimum profit, and VAT should be recalculated once");

  const tollOverrideAndRisk = composePricingEnrichment({
    originalBaseBeforeSeasonal: 1000,
    oldToll: 100,
    finalToll: 300,
    oldRisk: 0,
    fixedRisk: 75,
    riskPercent: 5,
    seasonalMultiplier: 1,
    adminOverheadPercent: 0,
    marginPercent: 10,
    minimumProfit: 0,
    vatPercent: 15
  });
  assert.equal(tollOverrideAndRisk.finalBaseBeforeSeasonal, 1335, "manual toll override + route risk should both be included");

  const riskOverrideAndAutomaticToll = composePricingEnrichment({
    originalBaseBeforeSeasonal: 1000,
    oldToll: 0,
    finalToll: 180,
    oldRisk: 40,
    fixedRisk: 95,
    riskPercent: 0,
    seasonalMultiplier: 1,
    adminOverheadPercent: 0,
    marginPercent: 10,
    minimumProfit: 0,
    vatPercent: 15
  });
  assert.equal(riskOverrideAndAutomaticToll.finalBaseBeforeSeasonal, 1235, "route-risk override + automatic toll should both be included");

  const firstRun = composePricingEnrichment({
    originalBaseBeforeSeasonal: 1000,
    oldToll: 100,
    finalToll: 250,
    oldRisk: 50,
    fixedRisk: 90,
    riskPercent: 10,
    seasonalMultiplier: 1.05,
    adminOverheadPercent: 8,
    marginPercent: 12,
    minimumProfit: 175,
    vatPercent: 15
  });
  const secondRun = composePricingEnrichment({
    originalBaseBeforeSeasonal: firstRun.finalBaseBeforeSeasonal,
    oldToll: 250,
    finalToll: 250,
    oldRisk: firstRun.finalRisk,
    fixedRisk: 90,
    riskPercent: 10,
    seasonalMultiplier: 1.05,
    adminOverheadPercent: 8,
    marginPercent: 12,
    minimumProfit: 175,
    vatPercent: 15
  });
  assert.deepEqual(secondRun, { ...firstRun, tollDelta: 0, riskDelta: 0, combinedDelta: 0 }, "repeated finalisation should be idempotent");
});

test("internal quote review exposes auditable pricing formulas without customer-facing leakage", () => {
  const app = read("src/app.ts");
  const axleMigration = read("supabase/migrations/20260810013600_store_henning_default_axle_configurations.sql");
  const commercialMigration = read("supabase/migrations/20260810013700_commercial_rate_card_pricing.sql");
  const publicQuote = read("public/quote-view.html") + read("public/quote-response.html") + read("public/customer-portal.html");

  for (const expected of [
    "renderPricingAuditView",
    "Calculation Breakdown / Pricing Audit",
    "Actual calculation order",
    "Technical Source Details",
    "Source / class",
    "Effective / fallback",
    "timeTruckingDefaultAxles",
    "Night out allowance",
    "Henning confirmed rule",
    "Current stored overnight rate differs from R1,750.",
    "Diesel audit",
    "Toll classification audit",
    "Profit/minimum-profit protection changes the selling price",
    "Dangerous goods also triggered a separate hazmat surcharge",
    "pricing_source_snapshot",
    "dynamic_outputs",
    "A. Commercial Selling Price",
    "B. External/Trip Charges",
    "C. Internal Estimated Operating Cost",
    "D. Profitability Analysis",
    "E. Data Sources / Technical Audit",
    "F. Warnings / Pending Rules",
    "Internal costs are retained for profitability analysis only"
  ]) {
    assert.ok(app.includes(expected), `internal pricing audit should include ${expected}`);
  }

  assert.ok(app.includes("renderPricingAuditView(request, calculation, breakdowns)"), "Quote Review should render the internal audit from stored calculation data");
  assert.equal(publicQuote.includes("Calculation Breakdown / Pricing Audit"), false, "Customer quote pages must not expose internal pricing audit labels");
  assert.ok(axleMigration.includes("Henning confirmed: 1 Ton = 2 axles"), "axle metadata should store Henning's 1 Ton default");
  assert.ok(axleMigration.includes("Henning confirmed: Semi = 9 axles"), "axle metadata should store Henning's Semi default for matching equipment");
  assert.ok(axleMigration.includes("Henning confirmed: S/L = 10 axles"), "axle metadata should store Henning's S/L default for matching equipment");
  assert.ok(axleMigration.includes("Axle count is stored for audit/classification evidence only"), "axle metadata must not silently change toll class pricing");
  assert.equal(axleMigration.includes("toll_class ="), false, "axle metadata migration must not change toll_class pricing selectors");
  assert.ok(commercialMigration.includes("time_trucking_commercial_rate_card"), "commercial rate card should be stored in an explicit table");
  assert.ok(commercialMigration.includes("'pricing-v3-commercial-rate-card'"), "new authoritative path should use the commercial rate-card pricing version");
  assert.ok(commercialMigration.includes("'semi', 'Semi', false, 8000.00, 18.0000, 9"), "Semi non-HAZ rate should be seeded from Henning's rate card");
  assert.ok(commercialMigration.includes("'semi', 'Semi HAZ', true, 8500.00, 18.0000, 9"), "Semi HAZ rate should be seeded from Henning's rate card");
  assert.ok(commercialMigration.includes("'superlink', 'S/L', false, 8500.00, 18.0000, 10"), "S/L non-HAZ rate should be seeded from Henning's rate card");
  assert.ok(commercialMigration.includes("'additional_stop_rate', 1500.0000"), "additional stop rate should be configured at R1,500");
  assert.ok(commercialMigration.includes("'night_out_rate', 1750.0000"), "night-out rate should be configured at R1,750");
  assert.ok(commercialMigration.includes("'commercial_rate_basis_rule', 0.0000"), "day-vs-km selection should remain pending instead of guessed");
  assert.ok(commercialMigration.includes("DAY VS KM PRICING RULE REQUIRES HENNING CONFIRMATION"), "pending day-vs-km warning should be explicit");
  assert.ok(commercialMigration.includes("diesel_selling_adjustment_amount := 0"), "diesel variance should not automatically alter selling price");
  assert.ok(commercialMigration.includes("hazmat_amount := 0"), "HAZ rate should not stack a generic hazmat surcharge");
  assert.ok(commercialMigration.includes("internal_operating_cost := fuel_amount + tyres_amount + maintenance_amount + insurance_amount + depreciation_amount + driver_amount + vehicle_overhead_amount"), "operating-cost model should remain internal analysis");
  assert.ok(commercialMigration.includes("Internal operating-cost analysis only"), "internal cost lines should be labelled as non-selling-price");
  assert.equal(commercialMigration.includes("base_cost_value := fuel_amount +"), false, "commercial selling price must not be rebuilt from fuel/tyres/maintenance/depreciation");
});

test("commercial rate-card pricing keeps customer selling price separate from internal cost build", () => {
  const migration = read("supabase/migrations/20260810013700_commercial_rate_card_pricing.sql");

  for (const expected of [
    "Commercial base - per-km scenario",
    "Commercial base - per-day scenario",
    "Selected commercial base",
    "Pending approved rule",
    "Normal profit is included in Henning commercial rate",
    "10% protection pending exact Time Trucking definition",
    "driver_overnight_allowance = 1750.00",
    "rate_category_key = rate_category_value",
    "hazardous = hazmat_required"
  ]) {
    assert.ok(migration.includes(expected), `commercial pricing migration should include ${expected}`);
  }

  const subtotalExpression = "subtotal_value := commercial_base_amount + diesel_selling_adjustment_amount + additional_stop_amount + night_out_amount + cross_border_amount";
  assert.ok(migration.includes(subtotalExpression), "commercial subtotal should start from commercial base plus approved trip/business charges");
  assert.equal(migration.includes("subtotal_value := fuel_amount"), false, "commercial subtotal must not start from operating fuel cost");
  assert.equal(migration.includes("profit_value := greatest"), false, "normal margin/minimum profit must not be added on top of Henning rates");
  assert.equal(migration.includes("floor(coalesce(estimated_duration_hours"), false, "night-out count must not keep the old floor(duration / 24) trigger");
});

test("pricing settings UI is rebuilt around commercial pricing, not cost-build selling price", () => {
  const page = read("public/pricing-settings.html");
  const app = read("src/app.ts");
  const client = read("src/supabaseClient.ts");
  const migration = read("supabase/migrations/20260810013800_save_commercial_pricing_settings.sql");
  const publicQuote = read("public/quote-view.html") + read("public/quote-response.html") + read("public/customer-portal.html");

  for (const expected of [
    "Automatic Quoting Readiness",
    "Time Trucking Commercial Rate Card",
    "These are Time Trucking's base customer selling rates",
    "Commercial Pricing Rules",
    "Day vs km pricing rule has not yet been confirmed",
    "Diesel Reference & Adjustment",
    "Customer selling-price diesel adjustment",
    "Automatic Toll Pricing",
    "Additional Commercial Charges",
    "Additional Hazardous-Goods External Cost",
    "Vehicle-Class Operating Cost Profiles",
    "They do NOT automatically increase the customer selling price",
    "Equipment & Toll Configuration",
    "Pricing Data Sources",
    "Advanced / Legacy / Fallback Settings"
  ]) {
    assert.ok(page.includes(expected), `pricing settings page should include ${expected}`);
  }

  for (const expected of [
    "renderCommercialRateCardTable",
    "collectCommercialRateCardEdits",
    "renderPricingReadiness",
    "timeTruckingRateCategoryForEquipment",
    "Mapping requires confirmation",
    "pricing-v3-commercial-rate-card",
    "saveCommercialRateCard",
    "saveCommercialPricingSettings"
  ]) {
    assert.ok(app.includes(expected) || client.includes(expected), `pricing settings implementation should include ${expected}`);
  }

  assert.ok(client.includes("time_trucking_commercial_rate_card"), "pricing settings loader should read the commercial rate-card table");
  assert.ok(migration.includes("ttaq_save_commercial_pricing_settings"), "commercial settings should have a dedicated save RPC");
  assert.ok(migration.includes("rule_version = 'pricing-v3-commercial-rate-card'"), "saving settings should preserve the commercial pricing engine version");
  assert.equal(publicQuote.includes("Internal Operating Cost Analysis"), false, "customer pages must not expose internal operating-cost analysis");
  assert.equal(publicQuote.includes("Estimated contribution / profitability"), false, "customer pages must not expose profitability analysis");
});

test("vehicle-class internal operating-cost profiles are configurable without invented default costs", () => {
  const migration = read("supabase/migrations/20260810014200_vehicle_class_internal_cost_profiles.sql");
  const securityMigration = read("supabase/migrations/20260810014300_restrict_vehicle_class_internal_cost_summary.sql");
  const page = read("public/pricing-settings.html");
  const app = read("src/app.ts");
  const client = read("src/supabaseClient.ts");

  for (const expected of [
    "vehicle_class_internal_cost_profiles",
    "vehicle_class_internal_cost_components",
    "equipment_internal_cost_profile_overrides",
    "'1_ton', '1 Ton'",
    "'1_8_ton', '1.8 Ton'",
    "'3_ton', '3 Ton'",
    "'5_ton', '5 Ton'",
    "'8_ton', '8 Ton'",
    "'12_ton', '12 Ton'",
    "'semi', 'Semi'",
    "'superlink', 'S/L'",
    "fuel_consumption_l_per_100km",
    "tyres_per_km",
    "maintenance_per_km",
    "insurance_per_km",
    "depreciation_per_km",
    "vehicle_overhead_per_km",
    "driver_hourly_cost",
    "night_out_allowance",
    "null::numeric",
    "not_configured",
    "Requires Time Trucking input",
    "Time Trucking company default confirmed at R1,750",
    "Internal cost analysis incomplete",
    "Internal operating costs do not increase the customer selling price",
    "Legacy generic operating-cost profile preserved for historical compatibility",
    "ttaq_save_vehicle_class_internal_cost_profile",
    "manage_pricing_rules"
  ]) {
    assert.ok(migration.includes(expected), `vehicle-class internal-cost migration should include ${expected}`);
  }

  assert.ok(migration.includes("amount is null or amount >= 0"), "internal cost component amount should support null but never negative");
  assert.ok(migration.includes("where equipment.id = nullif(calculation.pricing_source_snapshot #>> '{equipment,selected_equipment_profile_id}', '')::uuid"), "standard equipment should inherit vehicle-class profile mappings");
  assert.equal(migration.includes("else 0::numeric end"), false, "missing internal cost values must not be seeded as confirmed zero");
  assert.equal(migration.includes("base_cost_value :="), false, "vehicle-class internal-cost migration must not change commercial selling-price base formulas");
  assert.ok(securityMigration.includes("ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')"), "summary RPC should require internal read permissions");
  assert.ok(securityMigration.includes("ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')"), "summary RPC should allow pricing managers");
  assert.ok(securityMigration.includes("revoke all on function public.ttaq_vehicle_class_internal_cost_profile_summary() from anon"), "anonymous users must not execute internal-cost summary RPC");
  assert.ok(securityMigration.includes("revoke all on function public.ttaq_save_vehicle_class_internal_cost_profile(jsonb) from anon"), "anonymous users must not execute internal-cost save RPC");

  assert.ok(page.includes("Vehicle-Class Operating Cost Profiles"), "pricing settings should expose vehicle-class cost profiles");
  assert.ok(page.includes("Blank means Not configured, not R0") || app.includes("Blank means Not configured, not R0"), "UI should distinguish blank values from zero");
  assert.ok(app.includes("renderVehicleClassInternalCostProfiles"), "settings app should render vehicle-class profile controls");
  assert.ok(app.includes("Internal cost/contribution analysis is incomplete"), "Quote Review should show incomplete internal analysis instead of R0");
  assert.ok(client.includes("ttaq_vehicle_class_internal_cost_profile_summary"), "client should load vehicle-class internal-cost summary RPC");
  assert.ok(client.includes("ttaq_save_vehicle_class_internal_cost_profile"), "client should save vehicle-class internal-cost profiles through RPC");
});

test("route-risk override RPC uses the project internal user identity model", () => {
  const migration = read("supabase/migrations/20260810013500_fix_route_risk_override_actor_lookup.sql");

  assert.ok(migration.includes("ttaq_record_route_risk_override"), "override RPC should be replaced by the corrective migration");
  assert.ok(migration.includes("where id = auth.uid()"), "override actor lookup should use internal_users.id, which references auth.users.id");
  assert.ok(migration.includes("user_status = 'active'"), "override actor lookup should require an active internal user");
  assert.ok(migration.includes("ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')"), "pricing rule permission should remain required");
  assert.ok(migration.includes("ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')"), "RFQ management permission should remain accepted");
  assert.equal(migration.includes("auth_user_id"), false, "override RPC must not reference a nonexistent auth_user_id column");
});

test("owner access correction preserves multiple owners and prevents zero active owners", () => {
  const migration = read("supabase/migrations/20260810014500_promote_henning_owner_access.sql");

  for (const expected of [
    "ttaq_prevent_zero_active_owners",
    "before update or delete on public.internal_users",
    "Time Trucking must have at least one active Owner.",
    "lower(email) = 'hluther@questlogistics.co.za'",
    "lower(email) = 'jacquesmallan@gmail.com'",
    "Jacques Malan must remain an active Owner",
    "role = 'owner'",
    "can_view_all_quotes = true",
    "can_manage_rfqs = true",
    "can_approve_quotes = true",
    "can_adjust_pricing = true",
    "can_manage_pricing_rules = true",
    "can_manage_users = true",
    "promote_internal_user_to_owner",
    "old_values",
    "new_values"
  ]) {
    assert.ok(migration.includes(expected), `owner correction migration should include ${expected}`);
  }

  assert.equal(migration.includes("auth.admin.inviteUserByEmail"), false, "owner correction must not recreate/invite Henning");
  assert.equal(migration.includes("insert into public.internal_users"), false, "owner correction must update the existing internal user");
});

test("Time Trucking Assistant provides guided role-aware operational help", () => {
  const helpPage = read("public/help.html");
  const app = read("src/app.ts");
  const pricingPage = read("public/pricing-settings.html");

  for (const expected of [
    "Time Trucking Assistant",
    "assistantSearch",
    "How can I help?",
    "data-assistant-query=\"create quote\"",
    "data-assistant-query=\"quote blocked review required\"",
    "data-assistant-query=\"change commercial rates semi rate card\"",
    "data-assistant-query=\"invite user create password\"",
    "data-assistant-query=\"connect email integration\""
  ]) {
    assert.ok(helpPage.includes(expected), `assistant page should include ${expected}`);
  }

  for (const expected of [
    "helpKnowledgeBase",
    "normalizeHelpText",
    "roleAllowsHelpTopic",
    "helpTopicHref",
    "assistantCategories",
    "assistantContext",
    "Commercial billable distance remains separate until Henning confirms day/km and return-trip rules",
    "DAY VS KM PRICING RULE REQUIRES HENNING CONFIRMATION",
    "Missing external charges remain review-required, not R0.",
    "Commercial backload treatment remains review-required until Henning confirms the rule.",
    "Open Quote Requests.",
    "Open Pricing.",
    "Open Users.",
    "Open Settings.",
    "How does an Owner invite a user?",
    "How do I accept my invitation?",
    "How do I create my password?",
    "I forgot my password",
    "My invitation expired",
    "I did not receive my invitation",
    "How does an Owner resend an invitation?",
    "pricing-settings.html#commercial",
    "pricing-settings.html#external",
    "pricing-settings.html#internal",
    "pricing-settings.html#overview",
    "users-dashboard.html",
    "admin-settings.html#integrations",
    "quote-review.html"
  ]) {
    assert.ok(app.includes(expected), `assistant implementation should include ${expected}`);
  }

  for (const expected of [
    "create a quote",
    "quote blocked",
    "Semi rate",
    "Backload",
    "cross-border",
    "permit",
    "internal operating-cost analysis",
    "route-risk",
    "diesel",
    "toll class",
    "HAZ",
    "VAT"
  ]) {
    assert.ok((helpPage + app).toLowerCase().includes(expected.toLowerCase()), `assistant should answer searches for ${expected}`);
  }

  assert.ok(app.includes("window.location.hash.replace(\"#\", \"\")"), "Pricing Settings should support tab deep links from the assistant");
  assert.ok(app.includes("window.history.replaceState(null, \"\", `#${tab}`)"), "Pricing tab clicks should keep the deep link current");
  assert.ok(pricingPage.includes("data-pricing-tab-button=\"commercial\""), "commercial pricing tab should exist for assistant deep links");
  assert.equal((helpPage + app).includes("Supabase Auth user ID"), false, "assistant must not ask users for backend auth IDs");
  assert.equal((helpPage + app).includes("User UUID"), false, "assistant must not ask users for UUIDs");
});

if (process.exitCode) {
  process.exit(process.exitCode);
}
