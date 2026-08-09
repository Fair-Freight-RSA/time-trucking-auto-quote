const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const root = path.resolve(__dirname, "..");
const exists = (relativePath) => fs.existsSync(path.join(root, relativePath));
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), "utf8");

function maskedPresent(name) {
  return process.env[name] && String(process.env[name]).trim().length > 0;
}

function check(label, passed, detail) {
  const marker = passed ? "PASS" : "WARN";
  console.log(`${marker} ${label}${detail ? ` - ${detail}` : ""}`);
  return passed;
}

let warnings = 0;
const warn = (label, passed, detail) => {
  if (!check(label, passed, detail)) warnings += 1;
};

console.log("Time Trucking Auto-Quote production readiness check");
console.log("No secret values are printed by this script.\n");

warn("Supabase browser URL configured", maskedPresent("VITE_SUPABASE_URL"), "set VITE_SUPABASE_URL in the frontend environment");
warn("Supabase browser anon key configured", maskedPresent("VITE_SUPABASE_ANON_KEY"), "set VITE_SUPABASE_ANON_KEY in the frontend environment");
warn("Google Maps browser key configured", maskedPresent("VITE_GOOGLE_MAPS_API_KEY"), "route automation falls back to manual estimates without it");
warn("Application public URL configured", maskedPresent("APP_PUBLIC_URL"), "needed for quote links in server-side email");
warn("Email provider selected", maskedPresent("EMAIL_PROVIDER"), "supported: resend, sendgrid, postmark");
warn("Verified sender configured", maskedPresent("EMAIL_FROM_ADDRESS"), "required for real email delivery");
warn(
  "At least one provider API key configured",
  maskedPresent("RESEND_API_KEY") || maskedPresent("SENDGRID_API_KEY") || maskedPresent("POSTMARK_SERVER_TOKEN") || process.env.EMAIL_DRY_RUN === "true",
  "set a provider key or EMAIL_DRY_RUN=true for non-delivery testing"
);
warn("Service role secret configured for Edge Function", maskedPresent("SUPABASE_SERVICE_ROLE_KEY"), "must be an Edge Function secret only");
warn("Allowed origins configured", maskedPresent("ALLOWED_ORIGINS") || maskedPresent("APP_PUBLIC_URL"), "comma-separated production/local origins");

warn("production-integrations Edge Function exists", exists("supabase/functions/production-integrations/index.ts"));
warn("production hardening migration exists", exists("supabase/migrations/20260706025000_production_readiness_hardening.sql"));
warn("quote-documents bucket is prepared by migration", read("supabase/migrations/20260706024000_production_integrations.sql").includes("'quote-documents'"));
warn("operational-documents bucket is prepared by migration", read("supabase/migrations/20260706024000_production_integrations.sql").includes("'operational-documents'"));

const appSource = exists("src/app.ts") ? read("src/app.ts") : "";
warn("no local fake user seed references in app", !appSource.includes("sample") && !appSource.includes("demo user"));
warn("public pages remain listed in auth guard as public-only exceptions", appSource.includes("client-rfq") && appSource.includes("quote-view") && appSource.includes("customer-portal"));

const build = spawnSync("npm", ["run", "build"], {
  cwd: root,
  stdio: "pipe",
  encoding: "utf8",
  shell: process.platform === "win32"
});
const buildOutput = `${build.stderr || ""}${build.stdout || ""}${build.error ? build.error.message : ""}`;
warn("build/typecheck succeeds", build.status === 0, build.status === 0 ? "" : buildOutput.slice(0, 500));

console.log(`\nReadiness result: ${warnings === 0 ? "ready for controlled deployment checks" : `${warnings} deployment warning(s) to resolve or consciously accept`}.`);
process.exit(0);
