# Time Trucking Auto-Quote

Private mobile-first transport quoting MVP for Time Trucking, designed to be linked from `timetrucking.co.za`.

This project is intentionally separate from Fair-Freight-RSA and CWC. It must use its own Supabase project and database.

## Batch 1 Scope

- Admin dashboard
- Create RFQ link page
- Client RFQ form page
- Quote review page
- Client quote response page
- Supabase migration for core quote system tables
- Quote status workflow foundation
- Vehicle/trailer suggestion placeholder
- Quote price adjustment and admin notes placeholder
- Email placeholder functions only, with no real sending
- Internal user access-control planning for owner, manager, staff, and viewer roles

## Project Structure

```text
time-trucking-auto-quote/
  public/
    index.html
    login.html
    admin-dashboard.html
    create-rfq-link.html
    client-rfq.html
    quote-review.html
    quote-response.html
    quote-view.html
    customer-portal.html
    jobs.html
    job-detail.html
    dispatch.html
    driver-job.html
    invoices.html
    invoice-detail.html
    reports.html
    fuel-slips.html
    pricing-settings.html
    admin-settings.html
    users-dashboard.html
    styles.css
  src/
    app.ts
    emailPlaceholders.ts
    supabaseClient.ts
    types.ts
    vite-env.d.ts
  supabase/
    migrations/
      20260706001000_time_trucking_auto_quote_core.sql
      20260706002000_internal_access_control_foundation.sql
      20260706003000_supabase_public_wiring.sql
      20260706004000_rfq_engine_foundation.sql
      20260706005000_vehicle_intelligence_engine.sql
      20260706006000_pricing_engine.sql
      20260706006100_pricing_seed_defaults.sql
      20260706007000_route_intelligence_foundation.sql
      20260706008000_quote_builder.sql
      20260706009000_quote_pdf_email_foundation.sql
      20260706010000_transport_job_conversion.sql
      20260706011000_dispatch_foundation.sql
      20260706012000_driver_operations_foundation.sql
      20260706013000_customer_portal.sql
      20260706014000_invoicing_foundation.sql
      20260706015000_internal_reports.sql
      20260706016000_admin_security_settings.sql
      20260706017000_final_qa_bugfixes.sql
      20260706018000_final_qa_quote_document_bugfix.sql
      20260706019000_fuel_slip_placeholders.sql
      20260706020000_dynamic_pricing_engine.sql
      20260706021000_google_maps_route_foundation.sql
      20260706022000_supabase_auth_internal_access.sql
  .env.example
  package.json
  tsconfig.json
```

## Local Development

```powershell
npm install
copy .env.example .env
npx tsc --noEmit
npm run dev
```

Then open `http://localhost:4174`.

## Time Trucking UI Theme

The project-wide interface is styled from `public/styles.css` as a shared Time Trucking design system. The visual direction follows the real Time Trucking website:

- Strong royal/deep blue branding on internal navigation and public header accents.
- White customer and manager work surfaces with subtle borders, professional card shadows, and restrained rounded panels.
- A compact TIME TRUCKING text/logo block, uppercase company branding, and the tagline `Safe. Reliable. On Time.` across the product.
- Consistent buttons, forms, tables, badges, empty states, warning states, and customer-safe quote panels.
- Internal pages use the blue Manager Portal sidebar and always provide a clear route back to `index.html`.
- Public pages use customer-facing Time Trucking branding without internal navigation or links to dashboards, reports, users, settings, fuel slips, pricing, or dispatch.
- Driver operations keep the same brand system but prioritize mobile readability and large action buttons.
- Shared page branding uses `.brand-shell`, `.brand-logo`, `.brand-copy`, `.brand-title`, and `.brand-subtitle`. Use this structure for new pages so the TIME TRUCKING logo keeps its proportions and never overlaps text.

Keep future UI work in this shared style layer first. Avoid introducing unrelated color themes or generic SaaS styling; success states may use green, but the product should continue to read as Time Trucking Auto-Quote.

## Supabase

Create a separate Supabase project for Time Trucking Auto-Quote. Do not use a Fair-Freight-RSA or CWC Supabase project.

1. Create the new project in Supabase.
2. In the SQL editor, run the migrations in this order:

```text
supabase/migrations/20260706001000_time_trucking_auto_quote_core.sql
supabase/migrations/20260706002000_internal_access_control_foundation.sql
supabase/migrations/20260706003000_supabase_public_wiring.sql
supabase/migrations/20260706004000_rfq_engine_foundation.sql
supabase/migrations/20260706005000_vehicle_intelligence_engine.sql
supabase/migrations/20260706006000_pricing_engine.sql
supabase/migrations/20260706006100_pricing_seed_defaults.sql
supabase/migrations/20260706007000_route_intelligence_foundation.sql
supabase/migrations/20260706008000_quote_builder.sql
supabase/migrations/20260706009000_quote_pdf_email_foundation.sql
supabase/migrations/20260706010000_transport_job_conversion.sql
supabase/migrations/20260706011000_dispatch_foundation.sql
supabase/migrations/20260706012000_driver_operations_foundation.sql
supabase/migrations/20260706013000_customer_portal.sql
supabase/migrations/20260706014000_invoicing_foundation.sql
supabase/migrations/20260706015000_internal_reports.sql
supabase/migrations/20260706016000_admin_security_settings.sql
supabase/migrations/20260706017000_final_qa_bugfixes.sql
supabase/migrations/20260706018000_final_qa_quote_document_bugfix.sql
supabase/migrations/20260706019000_fuel_slip_placeholders.sql
supabase/migrations/20260706020000_dynamic_pricing_engine.sql
supabase/migrations/20260706021000_google_maps_route_foundation.sql
supabase/migrations/20260706022000_supabase_auth_internal_access.sql
```

3. Copy `.env.example` to `.env`.
4. Add the Time Trucking Supabase values:

```text
VITE_SUPABASE_URL=https://your-time-trucking-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-time-trucking-anon-key
```

5. Restart the Vite dev server after changing `.env`.
6. Add `VITE_GOOGLE_MAPS_API_KEY` in `.env` for internal Google Maps route estimates. Keep the key out of source files, logs, screenshots, and README examples.
7. Public pages use secure token RPCs and do not need login.
8. Internal pages require Supabase Auth plus an active `internal_users` row.

## Security Boundary

Public clients do not need login. They must only use secure links for:

- `client-rfq.html`
- `quote-response.html`
- `quote-view.html`
- `customer-portal.html`

Internal Time Trucking users must log in before accessing:

- Admin dashboard
- Create RFQ link
- Quote review and approvals
- Users dashboard
- Pricing rules
- Internal quote data

Module 18 replaces the frontend guard placeholder with Supabase Auth login and active internal-user checks.

## Batch 2 Supabase Wiring

- Public RFQ form calls `ttaq_submit_public_rfq`.
- Public quote response calls `ttaq_get_public_quote_response` and `ttaq_record_public_quote_response`.
- Admin dashboard loads `quote_requests` and `quote_items` through Supabase when the internal guard passes.
- Quote review loads the selected RFQ, updates admin notes and adjusted price, and changes status through `ttaq_update_internal_quote_review`.
- Email remains placeholder-only through `notifications` rows and local template builders.

## Module 3 Vehicle Intelligence

Module 3 adds an automatic vehicle/trailer recommendation engine that runs after a final RFQ enters admin review.

Database support:

- `vehicle_recommendations`
- `equipment_rules`
- `transport_requirement_flags`

The engine calculates total cargo weight, total cargo volume, maximum item dimensions, total cargo value, dangerous goods, temperature control, fragile cargo, crane/forklift requirements, abnormal load risk, permit/escort flags, truck count, and utilization percentages.

Admin review shows a highlighted Vehicle Intelligence card before pricing with:

- recommended vehicle and trailer
- number of trucks
- payload and volume utilization
- warning flags
- manager review notes
- manual override placeholder

Email, PDF, pricing, and real authentication remain placeholders.

## Module 4 Pricing Engine

Module 4 adds a configurable, traceable pricing engine. Prices are not hard-coded in the app or function logic; Time Trucking configures the active pricing profile.

Database support:

- `pricing_profiles`
- `fuel_price_history`
- `vehicle_operating_costs`
- `driver_costs`
- `company_overheads`
- `pricing_calculations`
- `pricing_breakdowns`
- `pricing_adjustments`
- `pricing_settings`

The engine stores every calculation step as breakdown rows for fuel, driver, maintenance, insurance, depreciation, overhead, escort, permit, hazmat, refrigeration, crane, forklift, profit, and VAT.

Internal pages:

- `pricing-settings.html` configures the active pricing profile.
- Quote review shows a Pricing Summary card with cost breakdown, subtotal, profit, VAT, and recommended selling price.
- Managers can enter an override price and reason; override history is stored in `pricing_adjustments`.

Email, PDF, real authentication, and final production pricing governance remain placeholders.

## Module 5 Route Intelligence

Module 5 adds a route-estimate foundation between Vehicle Intelligence and Pricing. Manual estimates remain available so admins can enter distance and duration and feed those values into the pricing engine.

Database support:

- `route_estimates`
- `route_estimate_stops`
- `route_provider_logs`

Route estimates store origin, destination, ordered stops, distance, duration, provider name, provider response JSON, external route ID, nullable geocoded coordinates, confidence level, and manual override audit fields.

Automatic workflow:

- Final RFQ submission moves the request into admin review.
- Vehicle Intelligence generates the vehicle/trailer recommendation.
- Route Intelligence creates a manual placeholder route estimate.
- Pricing uses the route estimate distance and duration.

Admin review now shows a Route Intelligence card above Pricing with:

- ordered route stops
- estimated distance and duration
- manual/provider label
- distance and duration edit placeholder
- regenerate pricing placeholder button

Google Maps route estimation is added in Module 17. HERE Maps, live geocoding enrichment, route alternatives, and production route audit governance remain future work.

## Module 6 Professional Quote Builder

Module 6 turns approved pricing into a versioned, customer-facing quote document while keeping internal pricing details private.

Database support:

- `quote_documents`
- `quote_template_settings`
- `quote_customer_events`
- `quote_revision_requests`

The quote builder function `ttaq_generate_quote_document(quote_request_id uuid)` pulls from:

- `quote_requests`
- `quote_items`
- `quote_stops`
- `vehicle_recommendations`
- `route_estimates`
- `pricing_calculations`
- `pricing_breakdowns`

Each generated quote document stores a customer-safe payload with branding, quote number, quote date, validity date, customer details, stops, cargo summary, route estimate, recommended vehicle/trailer, final selling price, VAT, terms, accept/decline links, PDF placeholder URL, and version number.

The internal document payload also stores trace details such as pricing breakdown IDs and admin notes. Public customers never receive internal cost breakdown, profit, margin, or pricing-rule detail.

Admin review now includes placeholders for:

- Generate Quote
- Preview Customer Quote
- Mark as Sent
- Regenerate Quote
- Download PDF placeholder

Public customer page:

- `quote-view.html`

Customers can view the professional quote summary, accept, decline, request a revision placeholder, and see a PDF download placeholder. Email sending and real PDF generation remain future modules.

## Module 7 PDF and Email Foundation

Module 7 replaces the old PDF/email placeholders with a real document-generation foundation and audited email status tracking.

Database additions:

- `quote_documents.pdf_url`
- `quote_documents.pdf_storage_path`
- `quote_documents.generated_at`
- `quote_documents.email_sent_to`
- `quote_documents.email_status`
- `quote_documents.email_error`

Storage support:

- Private Supabase Storage bucket: `quote-documents`
- Internal users with approved quote/RFQ access can generate and access stored quote document files.
- Public customers cannot browse storage documents.
- Public quote document access remains controlled through the secure quote token/reference RPC.

New database functions:

- `ttaq_mark_quote_document_generated(...)`
- `ttaq_mark_quote_document_sent(...)`
- `ttaq_get_internal_quote_document(...)`
- Updated `ttaq_get_public_quote_document(...)`

What is real:

- Admin quote generation creates versioned quote documents.
- Regenerate Quote creates a new document version instead of overwriting history.
- Module 22 supersedes the earlier browser-print foundation with server-side customer-safe PDF generation and signed download URLs.
- Public `quote-view.html` can open the customer-safe generated PDF without exposing internal costing, margin, admin notes, approval metadata, users, or dashboards.
- Email send attempts are stored on `quote_documents` with `pending`, `simulated`, `failed`, or `sent` status.

What remains placeholder:

- Email delivery requires a configured Edge Function provider secret. Missing provider configuration records a visible `failed` status instead of silently pretending an email was sent.
- The current server-side PDF renderer is intentionally lightweight and can be upgraded later for richer branded layouts.

Validation:

```powershell
npm install
npx tsc --noEmit
```

## Module 8 Accepted Quote to Transport Job Conversion

Module 8 converts accepted customer quotes into internal transport jobs for operations.

Database support:

- `transport_jobs`
- `transport_job_stops`
- `transport_job_events`
- `transport_job_documents`

RPC functions:

- `ttaq_convert_quote_to_job(...)`
- `ttaq_get_internal_job(...)`
- `ttaq_list_internal_jobs(...)`
- `ttaq_update_job_status(...)`

Conversion rules:

- Only client accepted quotes can be converted.
- Only approved internal Time Trucking users with RFQ management access can convert quotes or update job status.
- A quote can only create one transport job; repeated conversion attempts return the existing job.
- The conversion copies customer-safe route, stop, cargo, vehicle, document, and scheduling information.
- Internal costing, margin, pricing breakdowns, admin notes, approval metadata, users, dashboards, and company-only data are not exposed to public users or copied into public views.

Internal pages:

- `jobs.html`
- `job-detail.html`

Quote Review now shows a Convert to Job button. It is enabled only after the client accepts the quote. If the quote was already converted, Quote Review links to the existing job instead of creating a duplicate.

## Module 9 Operations Dispatch

Module 9 adds an internal dispatch layer for converted transport jobs.

Database additions on `transport_jobs`:

- `driver_placeholder`
- `truck_placeholder`
- `dispatcher_notes`
- `planned_pickup_time`
- `planned_delivery_time`
- `actual_pickup_time`
- `actual_delivery_time`

Dispatch status flow:

- `draft`
- `scheduled`
- `active`
- `completed`
- `cancelled`

Internal dispatch page:

- `dispatch.html`

The dispatch board lists draft/scheduled jobs and active jobs separately. Internal users can save driver and truck placeholders, planned pickup/delivery times, and dispatcher notes. Start Job, Complete Job, and Cancel Job actions update job status and record every dispatch/status change in `transport_job_events`.

Public users cannot access dispatch; it is protected by Supabase Auth, active internal-user checks, and Supabase internal-user permission checks used by other internal pages.

## Module 10 Driver Operations and POD Foundation

Module 10 adds a basic internal driver workflow for active jobs.

Database/RPC support:

- `ttaq_record_driver_job_action(...)`
- Driver actions are stored in `transport_job_events`
- POD placeholder uploads create `transport_job_documents` rows with `document_type = 'pod_placeholder'`

Internal driver page:

- `driver-job.html`

The driver page loads an assigned active job, showing job details, stops, planned pickup/delivery times, driver/truck placeholders, and route summary. It includes simple action buttons:

- Arrived at pickup
- Pickup confirmed
- Arrived at delivery
- Delivery confirmed
- Upload POD placeholder

Pickup and delivery confirmations update actual pickup/delivery timestamps. Delivery confirmation completes the job. Driver operations data remains internal and is not exposed to public RFQ, quote response, or customer quote pages.

## Module 11 Customer Portal

Module 11 adds a customer-safe portal for quote and job progress visibility.

Public page:

- `customer-portal.html`

RPC:

- `ttaq_get_customer_portal(...)`

The portal requires the existing secure quote token or public reference lookup and returns only customer-safe data:

- quote status
- accepted/declined state
- quote document metadata
- linked job status
- pickup/delivery address summary
- planned pickup/delivery times
- POD placeholder status

The portal does not expose internal costing, margins, admin notes, dispatch notes, driver internal action logs, users, dashboards, or company-only operational data. `quote-view.html` links to the customer portal after quote acceptance.

## Module 12 Invoicing and Finance Tracking

Module 12 adds internal invoice generation and payment tracking placeholders for active/completed jobs.

Database support:

- `invoices`
- `invoice_line_items`
- `invoice_payments`

RPC functions:

- `ttaq_generate_invoice_from_job(...)`
- `ttaq_get_internal_invoice(...)`
- `ttaq_list_internal_invoices(...)`
- `ttaq_update_invoice_payment_status(...)`

Internal pages:

- `invoices.html`
- `invoice-detail.html`

Invoices can be generated from job detail. The system creates invoice line items from the customer-facing quote total and records payment placeholders/status changes. Only approved internal Time Trucking users can access invoice detail, line items, and payment tracking.

The customer portal shows only customer-safe invoice/payment status. It does not expose line items, internal finance notes, costing, margins, payment references, users, or dashboards.

## Module 13 Internal Reporting and Analytics

Module 13 adds an internal-only reporting dashboard for Time Trucking management visibility.

RPC function:

- `ttaq_get_internal_reports(...)`

Internal page:

- `reports.html`

The reports dashboard shows total RFQs, generated quotes, accepted/declined quotes, conversion rate, job status counts, invoice counts, paid/unpaid invoice counts, total quoted value, total invoiced value, and outstanding amount.

Reports are restricted to approved internal users with quote/RFQ permissions. Public clients cannot access analytics, reports, dashboards, internal quote data, costing, margins, invoice detail, or operational reporting.

## Module 14 Admin Security and Settings

Module 14 adds the internal settings foundation and audit trail for administrative changes.

Database support:

- `audit_logs`
- `system_settings`
- `company_branding_settings`
- `email_template_placeholders`
- `numbering_sequence_settings`

RPC functions:

- `ttaq_can_update_internal_settings(...)`
- `ttaq_get_internal_settings(...)`
- `ttaq_update_internal_settings(...)`

Internal page:

- `admin-settings.html`

Settings cover company branding placeholders, customer-safe quote footer text, placeholder email templates, RFQ/quote/job/invoice numbering sequences, public/internal security policy notes, document defaults, and notification defaults.

Only approved owner/admin users can update settings. Managers may read safe internal settings but cannot update restricted settings. Audit logs are owner-only. Public users cannot access settings, audit logs, users, reports, admin dashboards, internal quote data, or analytics.

## Module 15 Production Readiness Pass

Module 15 reviews the MVP foundation for production safety, placeholder clarity, deployment readiness, and final QA.

Public customer-safe pages:

- `client-rfq.html`
- `quote-response.html`
- `quote-view.html`
- `customer-portal.html`

These pages must only show RFQ entry fields, customer quote details, customer decisions, customer-safe job progress, customer-safe POD placeholder status, and customer-safe invoice/payment status. They must not show internal costing, margin, pricing breakdowns, admin notes, approval metadata, dispatch notes, driver internal logs, users, reports, audit logs, settings, or dashboards.

Internal guarded pages:

- `index.html`
- `admin-dashboard.html`
- `create-rfq-link.html`
- `quote-review.html`
- `jobs.html`
- `job-detail.html`
- `dispatch.html`
- `driver-job.html`
- `invoices.html`
- `invoice-detail.html`
- `reports.html`
- `fuel-slips.html`
- `pricing-settings.html`
- `admin-settings.html`
- `users-dashboard.html`

Internal pages use Supabase Auth, `internal_users`, RLS, and RPC permission checks. Public pages remain token/reference controlled and do not require login.

Provider placeholders that remain intentionally visible:

- Email: quote and invoice email actions use the production Edge Function. Missing provider secrets are shown and logged as failed sends.
- PDF: quote and invoice PDFs are generated server-side and opened through temporary signed URLs.
- Uploads: fuel slip files use private signed uploads. RFQ attachments/photos and full POD upload UI remain placeholders until their intake screens are expanded.
- Payments: invoice payment status is tracked manually; no live payment gateway is configured.
- Maps/routes: Google Maps route estimates are available for internal quote review when `VITE_GOOGLE_MAPS_API_KEY` is configured; manual route fallback remains available.

## Production Checklist

- Create and verify the separate hosted Time Trucking Supabase project.
- Confirm `.env` uses only the Time Trucking Supabase URL and anon key.
- Apply every migration from `supabase/migrations` to the hosted Supabase project in timestamp order.
- Create the first owner user in Supabase Auth and `internal_users`.
- Confirm RLS is enabled on internal tables and public access is limited to token/reference RPCs only.
- Verify Supabase Auth login/routing on every internal page.
- Configure production domain allowlists and redirect URLs for `timetrucking.co.za`.
- Configure the private `quote-documents` storage bucket and verify public users cannot browse files.
- Configure a real email provider before sending customer email in production.
- Decide whether server-side PDF rendering is required before go-live.
- Configure backup, audit-log retention, and operational monitoring.
- Review all customer-visible wording and Time Trucking branding.

## Hosted Supabase Migration Notes

For hosted Supabase, run migrations against the Time Trucking project only. Do not reuse Fair-Freight-RSA or CWC Supabase projects.

Recommended hosted flow:

1. Link the local project to the hosted Time Trucking Supabase project with the Supabase CLI.
2. Confirm the target project reference before pushing migrations.
3. Run the full migration set in timestamp order.
4. Verify required extensions such as `pgcrypto` are enabled.
5. Seed or invite the first owner/internal user.
6. Test public token RPCs from an anonymous session.
7. Test internal RPCs from an approved owner/manager session.
8. Confirm public users cannot select internal tables directly.

## Final QA Checklist

- RFQ submit: create a secure RFQ link, save draft, submit final RFQ, and confirm stops/items/dynamic answers are saved.
- Admin review: load submitted RFQ, confirm Vehicle Intelligence, Route Intelligence, and Pricing summaries render.
- Generate quote: approve/adjust price, generate customer-safe quote, preview quote, and verify no internal costing appears publicly.
- Customer accept/decline/revision request: open quote link, accept, decline on a separate test quote, and submit a revision request.
- Convert accepted quote to job: convert only an accepted quote and confirm duplicate conversion is blocked.
- Dispatch job: assign driver/truck placeholders, set planned times, start/cancel/complete status flows, and confirm events are recorded.
- Driver actions: open driver job page, record pickup/delivery check-ins, confirmations, and POD placeholder action.
- Fuel slips: record fuel slip placeholders from the driver job page and verify internal litres, amount, and VAT totals.
- Generate invoice: generate invoice from job, update manual payment status, and confirm customer portal shows safe invoice status only.
- Reports: open reports dashboard as an internal user and verify RFQ, quote, job, invoice, and value metrics.
- Admin settings: open settings as owner/admin, update placeholders, confirm audit log entry, and verify manager read-only behavior.

## Internal Roles

- `owner`: full access, can add/revoke users, approve quotes, and adjust pricing.
- `manager`: can review/approve quotes and manage RFQs, but cannot remove an owner.
- `staff`: can view assigned/internal quote information only when allowed, and cannot approve quotes by default.
- `viewer`: read-only internal access.

Quote approval must require `owner` or `manager` role, or an explicit `can_approve_quotes` permission. User access management must only be available to `owner` or `manager`, with owner accounts protected from accidental removal.

## Module 18 Supabase Auth

Module 18 replaces the old internal guard placeholder with real Supabase Auth.

- Internal login page: `login.html`
- Internal pages redirect to `login.html` when no valid Supabase Auth session exists.
- After login, the app calls `ttaq_get_current_internal_user()` and only allows users with an active `internal_users` record.
- Revoked users and users without an internal record see a professional access-pending message.
- Internal sidebar shows the signed-in user's name/email, role, and a real sign-out button.
- Public pages remain accessible without login: `client-rfq.html`, `quote-response.html`, `quote-view.html`, and `customer-portal.html`.
- RLS and RPC permission checks remain the source of truth for approvals, pricing, settings, reports, invoices, jobs, users, and other restricted workflows.

First owner bootstrap after a clean database reset:

1. Create the first user in Supabase Dashboard under Authentication.
2. Copy that user's Auth UID.
3. Run this SQL in the Time Trucking Supabase SQL editor, replacing the UID, email, and name:

```sql
insert into public.internal_users (
  id,
  email,
  full_name,
  role,
  user_status,
  can_view_all_quotes,
  can_manage_rfqs,
  can_approve_quotes,
  can_adjust_pricing,
  can_manage_pricing_rules,
  can_manage_users
)
values (
  'AUTH_USER_ID_HERE',
  'owner@timetrucking.co.za',
  'Time Trucking Owner',
  'owner',
  'active',
  true,
  true,
  true,
  true,
  true,
  true
);
```

4. Open `login.html` and sign in with that Supabase Auth user's email and password.

## Module 19 Real Manager Portal Dashboard

Module 19 turns `index.html` into the production internal Manager Portal landing page.

- Uses the logged-in Supabase Auth session and active `internal_users` profile loaded during Module 18 auth checks.
- Loads live Supabase data for RFQs, quote status, jobs, dispatch queue, invoices, outstanding balances, fuel slips, and reports.
- Shows role-aware quick actions for quotes, jobs, dispatch, pricing settings, fuel slips, reports, users, and settings.
- Hides restricted actions when the current role or permission flags do not allow them.
- Keeps public customer pages separate and unauthenticated.
- Shows clear loading and error states if Supabase calls fail.

## Access-Control Schema Notes

The access-control migration adds `internal_users` with:

- `role`
- `user_status`
- `invited_by`
- `revoked_at`
- `last_login_at`
- permission flags for quote visibility, RFQ management, quote approval, pricing, and user management

Use `revoked` status instead of deleting users so quote approvals and audit logs remain intact.

## Module 16 Fuel Slip Placeholders

Module 16 adds internal fuel slip capture for transport jobs, reporting, and tax records.

Database support:

- `fuel_slips`

RPC functions:

- `ttaq_upload_fuel_slip_placeholder(...)`
- `ttaq_list_internal_fuel_slips(...)`
- `ttaq_get_job_fuel_slips(...)`

Internal page:

- `fuel-slips.html`

Driver operations:

- `driver-job.html` includes a fuel slip placeholder form for active jobs.
- Fuel slips link to `transport_jobs` and capture driver/truck placeholders, slip date, fuel station, litres, amount, VAT amount, odometer, notes, and document URL/storage path placeholders.
- The internal fuel slips page shows total litres, total fuel amount, and total VAT amount for reporting and tax preparation.

Public customer pages never show fuel slips, driver fuel notes, tax records, document storage paths, or internal fuel reporting.

## Module 17 Dynamic Pricing Engine

Module 17 upgrades the existing pricing engine into an internal-only dynamic pricing system while reusing `ttaq_generate_price(...)`, `pricing_calculations`, `pricing_breakdowns`, and the existing manager override flow.

Database support:

- `pricing_seasonal_multipliers`
- `diesel_price_integrations`
- `toll_cost_rules`
- `route_risk_pricing_rules`
- `company_margin_profiles`
- `monthly_pricing_refreshes`
- `pricing_calculation_audit_events`
- `pricing_component_overrides`

Dynamic pricing features:

- Automatic fuel surcharge from current diesel price versus configured diesel baseline.
- Live diesel price integration foundation with admin override; the real provider remains placeholder-only until configured.
- Seasonal multipliers for low, normal, busy, and peak periods.
- Toll cost framework using configurable route rules and fallback toll settings.
- Route risk pricing framework using distance and route keyword rules.
- Vehicle operating cost profiles through `vehicle_operating_costs`.
- Company margin profiles for minimum, target, and premium margins.
- Monthly pricing refresh audit foundation.
- Detailed manager-only calculation breakdown and audit/history events.

Quote Review now includes an internal `Explain Calculation` panel showing diesel inputs, seasonal impact, toll/risk amounts, margin profile, overhead, profit, VAT, and calculation audit counts. Managers can record component override audit entries and still use the final selling-price override before approval.

Google Maps route foundation:

- `VITE_GOOGLE_MAPS_API_KEY` loads Google Maps only from the environment.
- Quote Review can estimate pickup/delivery or multi-stop route distance and duration with Google Maps.
- Successful estimates are stored as `google_maps` route estimates and immediately feed dynamic pricing.
- Managers can open the route in Google Maps, then keep the Google estimate or manually override distance/duration.
- If the key is missing or Google Maps fails, the UI shows a clear manager-visible message and keeps the manual route fallback.
- Customer portal directions use only customer-safe pickup/delivery addresses and never expose provider metadata or internal pricing.

Customer quote pages, quote PDFs/print views, and the customer portal never expose dynamic pricing inputs, internal costing, margins, route risk rules, audit logs, component overrides, or manager notes.

## Manager Portal

`index.html` is the main internal Manager Portal landing page for Time Trucking managers.

The portal shows daily operations summary cards for:

- New RFQs
- Quotes waiting review
- Quotes sent
- Accepted quotes
- Jobs scheduled
- Jobs active
- Jobs completed
- Invoices unpaid
- Outstanding amount
- Fuel slip totals

Manager action cards link to:

- Review RFQs
- Create RFQ Link
- Quotes
- Jobs
- Dispatch
- Driver Job View
- Invoices
- Reports
- Fuel Slips
- Users
- Settings

Managers can access operations, quotes, jobs, dispatch, invoices, reports, and fuel slips through the existing internal guard and Supabase permission model. Restricted settings and user-management changes remain owner/admin controlled where enforced by existing RPCs/RLS. Public customer pages do not expose Manager Portal data.

## Module 20 Google Maps Route Estimation Workflow

Module 20 wires the existing Google Maps foundation through Quote Review, route persistence, pricing refresh, jobs, dispatch, and driver/customer-safe route views.

Configuration:

- Set `VITE_GOOGLE_MAPS_API_KEY` in the local or hosted environment.
- Do not commit a real API key. `.env.example` documents the required variable names only.
- The browser key should be restricted in Google Cloud to the deployed Time Trucking domains and the required Maps JavaScript/Places/Directions APIs.

Implemented route behavior:

- Public RFQ stop address fields support Google Places autocomplete when the key is configured, while still accepting manual address text.
- Quote Review can calculate a multi-stop driving route with Google Maps Directions, render a route map preview, store distance/duration/source metadata, and regenerate pricing through the existing pricing engine.
- Route estimates store provider response details, stop coordinates/place IDs where available, encoded polyline metadata, toll availability status, route-risk status, and calculation timestamp.
- Toll values remain clearly marked as unavailable/manual/configured fallback unless a confirmed toll provider is added later.
- Route risk remains driven by the existing internal configurable route-risk pricing rules; the system does not invent external crime, road, or weather data.
- Jobs, job detail, dispatch, and driver job views show customer-safe operational route summaries and ordered stops.
- Customer-facing quote and portal views may show route addresses and estimated distance/duration, but never expose internal route risk, toll rules, pricing formulas, margins, or manager notes.

Fallbacks:

- If Google Maps is unavailable or the key is missing, Quote Review shows a clear error and keeps manual distance/duration override controls.
- Manual route overrides regenerate pricing and are visibly marked as manual/internal route data.

## Module 21 Production Page Audit

Module 21 removes remaining demo seeding, replaces local-only user management with live Supabase internal-user management, tightens page copy, and adds useful filtered dashboard navigation.

Audit checklist:

- `login.html`: live Supabase Auth login; configuration-required state if Supabase env vars are missing.
- `index.html`: live Operations Dashboard; metric cards link to filtered quote/job/invoice/fuel pages.
- `admin-dashboard.html`: compatibility redirect to guarded Operations Dashboard.
- `create-rfq-link.html`: live RFQ-link RPC; email provider remains configuration-required with message preview only.
- `client-rfq.html`: live public RFQ submission; address autocomplete when Google Maps is configured; upload storage remains configuration-required.
- `quote-review.html`: live RFQ queue and selected RFQ review; route calculation, pricing breakdown, quote document generation, sending status, and job conversion wired to existing backend.
- `quote-view.html`: live customer-safe quote document view and accept/decline/revision actions.
- `quote-response.html`: live customer accept/decline endpoint for secure quote response links.
- `customer-portal.html`: live customer-safe quote/job/invoice/POD status without internal pricing, users, dispatch notes, risk rules, or fuel slips.
- `jobs.html`: live job list with status filtering from dashboard links.
- `job-detail.html`: live job detail, route/stops/events/documents, status updates, and invoice generation.
- `dispatch.html`: live scheduled/active dispatch board with driver/truck references, planned times, route summary, notes, and status actions.
- `driver-job.html`: live driver-safe active job workflow, route/stops, pickup/delivery confirmations, POD document status, and fuel slip capture.
- `fuel-slips.html`: live fuel slip list, litres/amount/VAT totals, linked job references, and document-state fields.
- `invoices.html`: live invoice list with open/status filtering from dashboard links.
- `invoice-detail.html`: live invoice detail, line items, VAT/totals, linked job data, and manual payment recording.
- `reports.html`: live internal report RPC metrics; no sample financial values.
- `pricing-settings.html`: live configurable pricing save flow; pricing rule/provider values remain internal and permission-protected.
- `users-dashboard.html`: live `internal_users` list and add/update/revoke/reactivate flow for existing Supabase Auth user IDs; no local fake users.
- `admin-settings.html`: live settings/branding/email-template/numbering/audit view and save flow; integration status shows configured/not configured without exposing secrets.

Remaining external integrations intentionally unavailable until configured:

- Public RFQ attachment intake and full POD upload UI beyond the current operational document foundation.
- Payment gateway.
- Fleet/driver/trailer master-data system.
- Live toll provider; toll pricing uses configured/manual fallback.
- External route-risk, road-condition, weather, or crime data. Route risk remains internal configurable rule logic only.

## Module 22 Production Integration Wiring

Module 22 adds the production foundation for customer-safe PDF documents, outbound email delivery, private file storage, signed downloads, and driver fuel-slip uploads.

Implemented:

- `production-integrations` Supabase Edge Function for secure server-side document and email actions.
- Quote PDF generation stored privately in the `quote-documents` bucket.
- Invoice PDF generation stored privately in the `operational-documents` bucket.
- Signed URL retrieval for internal users and token/reference-controlled customer quote PDF downloads.
- Email provider abstraction for Resend, SendGrid, or Postmark via server-only Edge Function secrets.
- Quote and invoice email actions with provider status/error recording in `email_logs`, `quote_documents`, and `invoices`.
- Private operational document upload support for fuel slips through signed upload URLs.
- Storage bucket/policy migration for `quote-documents` and `operational-documents`.
- Admin Settings copy now shows that PDF/email/upload delivery depends on the deployed Edge Function and server secrets.

Security boundaries:

- Browser code only uses `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, and the browser-restricted `VITE_GOOGLE_MAPS_API_KEY`.
- `SUPABASE_SERVICE_ROLE_KEY`, email provider API keys, sender identity, and `APP_PUBLIC_URL` must be configured as Supabase Edge Function secrets only.
- Public quote pages never receive storage paths, service-role credentials, internal costing, margins, admin notes, pricing breakdowns, fuel slips, dispatch notes, or user/admin data.
- Public quote PDF access is handled through the existing quote token/reference lookup and a temporary signed URL.

Required hosted setup:

1. Apply migrations:
   `supabase migration up`
2. Deploy the Edge Function:
   `supabase functions deploy production-integrations`
3. Set server-only secrets, choosing one provider:
   `supabase secrets set APP_PUBLIC_URL=https://your-domain.example EMAIL_PROVIDER=resend EMAIL_FROM_ADDRESS=quotes@your-domain.example EMAIL_FROM_NAME="Time Trucking" RESEND_API_KEY=your-provider-key SUPABASE_SERVICE_ROLE_KEY=your-service-role-key`
4. Keep `.env`/hosting environment variables limited to browser-safe values:
   `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_GOOGLE_MAPS_API_KEY`.

Provider behavior:

- If no provider secret is configured, email actions fail visibly and store `failed` with an error message. The app does not silently pretend email was sent.
- PDFs are intentionally customer-safe summaries. They do not include internal cost breakdowns, route-risk internals, margin profiles, approval metadata, or admin notes.
- The included PDF renderer is a lightweight server-side foundation. It can be replaced later by a richer renderer without changing the frontend flow.

## Module 23 Production Readiness

Module 23 adds a focused production-readiness hardening pass and acceptance-test foundation.

Security and integrity changes:

- Added `20260706025000_production_readiness_hardening.sql`.
- Added non-negative route, invoice, invoice line, and payment constraints.
- Added status constraints for transport jobs and invoices.
- Added positive stop-order constraints.
- Added safe storage-path constraints for quote/job document paths.
- Added dashboard/report indexes for quote status, job status, invoice status, email logs, and stop ordering.
- Hardened the `production-integrations` Edge Function:
  - fixed action allowlist
  - UUID validation
  - storage path validation
  - MIME and file-size enforcement
  - restricted upload targets
  - token/reference validation for public quote PDF access
  - recipient locking to the customer email on the quote/invoice
  - duplicate send prevention unless an explicit resend flow is later added
  - production/local CORS allowlist through `ALLOWED_ORIGINS`
  - deterministic `EMAIL_DRY_RUN=true` mode that records failed/non-delivered status instead of pretending success

Automated checks:

```powershell
npm run test
npm run test:production-readiness
```

`npm run test` performs static acceptance checks for:

- no service-role or provider secrets in browser files
- Edge Function action/payload/security guardrails
- token/reference-mediated public PDF access
- hardening migration constraints
- deterministic financial rounding vector

`npm run test:production-readiness` performs a non-secret deployment readiness check and reports warnings for missing production configuration. It does not print secret values.

Production environment configuration:

Browser-safe frontend variables:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`
- `VITE_GOOGLE_MAPS_API_KEY`

Static frontend hosting target:

- Recommended production URL: `https://quote.timetrucking.co.za`
- Frontend build command: `npm run build`
- Frontend output directory: `dist`
- Required public RFQ URL for the Time Trucking website CTA: `https://quote.timetrucking.co.za/client-rfq.html`
- Production customer quote URLs: `https://quote.timetrucking.co.za/quote-view.html?ref=TTAQ-...`
- Cloudflare Pages settings: build command `npm run build`, output directory `dist`
- Netlify fallback settings: build command `npm run build`, publish directory `dist`

Server-only Edge Function secrets:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `APP_PUBLIC_URL`
- `ALLOWED_ORIGINS`
- `EMAIL_PROVIDER`
- `EMAIL_FROM_ADDRESS`
- `EMAIL_FROM_NAME`
- `EMAIL_DRY_RUN`
- `RESEND_API_KEY` or `SENDGRID_API_KEY` or `POSTMARK_SERVER_TOKEN`

Future Supabase production URL settings:

```powershell
supabase secrets set APP_PUBLIC_URL=https://quote.timetrucking.co.za ALLOWED_ORIGINS=https://quote.timetrucking.co.za,http://localhost:4174
```

Supabase Auth URL configuration:

- Site URL: `https://quote.timetrucking.co.za`
- Redirect allow-list:
  - `https://quote.timetrucking.co.za/login.html`
  - `https://quote.timetrucking.co.za/index.html`
  - `https://quote.timetrucking.co.za/**`
  - `http://localhost:4174/**`
  - `http://127.0.0.1:4174/**`

External production configuration:

- Restrict Google Maps browser key to production domains and required Maps JavaScript/Places/Directions APIs.
- Configure Supabase Auth site URL and redirect URLs for the production domain and approved local development URL.
- Deploy `production-integrations` Edge Function and set secrets with `supabase secrets set`.
- Verify `quote-documents` and `operational-documents` buckets are private.
- Verify email provider sender/domain DNS records before disabling dry-run mode.
- Keep service-role and provider keys out of frontend hosting variables.

Controlled launch checklist:

- Create/link the production Time Trucking Supabase project.
- Confirm there is a current backup or disposable pre-launch database state.
- Apply the full migration chain with `supabase migration up` or hosted migration deployment.
- Deploy `production-integrations`.
- Set Edge Function secrets.
- Verify storage buckets and policies.
- Configure Supabase Auth URL and redirect allowlist.
- Configure Google Maps API key restrictions.
- Configure email provider domain/sender DNS.
- Configure frontend browser environment variables.
- Deploy frontend to the production domain.
- Create the first Supabase Auth owner and matching `internal_users` owner row.
- Run `npm run test`, `npm run test:production-readiness`, `npm run build`, and `supabase migration up`.
- Run one acceptance RFQ from a public link on mobile and desktop.
- Generate a quote PDF, send/dry-run quote email, and verify `email_logs`.
- Accept the quote as customer, open the customer portal, and verify no internal data appears.
- Convert the accepted quote to a job.
- Dispatch the job, run driver actions, upload a fuel slip, and verify event history.
- Generate invoice, PDF, email/dry-run email, record payment, and verify outstanding balance.
- Verify reports, users, pricing settings, and admin settings as owner/manager/viewer.
- Monitor Supabase logs, Edge Function logs, and provider email logs after launch.

Rollback plan:

- Disable frontend deployment or redirect internal links to maintenance copy.
- Re-enable `EMAIL_DRY_RUN=true` if email behavior is questionable.
- Stop using the Edge Function by removing provider secrets while keeping database records intact.
- Restore the latest Supabase backup if a destructive data issue is discovered.
- Redeploy the last known-good frontend build and Edge Function version.

Local workflow coverage limits:

- Real email delivery can only be proven with real provider credentials and verified DNS.
- Hosted CORS, Auth redirect behavior, and Google API domain restrictions must be verified on the production domain.
- Signed URL expiry and storage policies are migration-backed locally, but final verification should be performed against the hosted project.
- Edge Function type/lint checks require a Deno/Supabase Edge local toolchain; the current npm checks validate the browser app and static hardening expectations.
