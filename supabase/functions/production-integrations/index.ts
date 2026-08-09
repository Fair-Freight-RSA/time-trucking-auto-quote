import { createClient } from "https://esm.sh/@supabase/supabase-js@2.101.1";

type JsonMap = Record<string, unknown>;
type IntegrationStage =
  | "validate_request"
  | "authenticate_internal_user"
  | "document_lookup_failed"
  | "quote_pdf_generate_failed"
  | "quote_pdf_signed_url_failed"
  | "customer_quote_link_failed"
  | "email_provider_failed"
  | "email_log_failed"
  | "quote_mark_sent_failed"
  | "return_response_failed"
  | "unhandled_error";
type EmailResult = {
  status: "sent" | "failed";
  provider: string;
  providerMessageId: string | null;
  error: string | null;
  response: JsonMap;
};
type IntegrationAction =
  | "generate_quote_pdf"
  | "generate_invoice_pdf"
  | "get_quote_pdf_url"
  | "get_internal_document_url"
  | "create_upload_signed_url"
  | "record_uploaded_document"
  | "auto_route_public_rfq"
  | "send_quote_email"
  | "send_invoice_email";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const appPublicUrl = (Deno.env.get("APP_PUBLIC_URL") ?? "").replace(/\/$/, "");
const allowedOrigins = (Deno.env.get("ALLOWED_ORIGINS") ?? appPublicUrl)
  .split(",")
  .map((origin) => origin.trim().replace(/\/$/, ""))
  .filter(Boolean);
const emailProvider = (Deno.env.get("EMAIL_PROVIDER") ?? "").toLowerCase();
const emailFrom = Deno.env.get("EMAIL_FROM_ADDRESS") ?? "";
const emailFromName = Deno.env.get("EMAIL_FROM_NAME") ?? "Time Trucking";
const dryRunEmail = (Deno.env.get("EMAIL_DRY_RUN") ?? "").toLowerCase() === "true";
const googleRoutesApiKey = Deno.env.get("GOOGLE_ROUTES_API_KEY") ?? "";

const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false }
});

function corsHeaders(req: Request): Record<string, string> {
  const requestOrigin = req.headers.get("origin")?.replace(/\/$/, "") ?? "";
  const localAllowed = requestOrigin.startsWith("http://localhost:")
    || requestOrigin.startsWith("http://127.0.0.1:");
  const origin = allowedOrigins.includes(requestOrigin) || localAllowed ? requestOrigin : (allowedOrigins[0] ?? "");
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin"
  };
}

function json(req: Request, status: number, payload: JsonMap): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders(req), "content-type": "application/json" }
  });
}

function errorMessage(error: unknown, fallback = "Request failed."): string {
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object" && "message" in error) return clean((error as { message?: unknown }).message, fallback);
  return fallback;
}

class IntegrationStageError extends Error {
  stage: IntegrationStage;

  constructor(stage: IntegrationStage, error: unknown) {
    super(errorMessage(error));
    this.name = "IntegrationStageError";
    this.stage = stage;
  }
}

async function atStage<T>(stage: IntegrationStage, task: () => Promise<T>): Promise<T> {
  try {
    return await task();
  } catch (error) {
    if (error instanceof IntegrationStageError) throw error;
    throw new IntegrationStageError(stage, error);
  }
}

function clean(value: unknown, fallback = ""): string {
  return String(value ?? fallback).replace(/\s+/g, " ").trim();
}

function safeFileName(value: string): string {
  return clean(value, "document").replace(/[^a-z0-9_.-]+/gi, "-").replace(/-+/g, "-").slice(0, 120);
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function isEmail(value: unknown): value is string {
  return typeof value === "string" && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) && value.length <= 254;
}

function safeEmailProviderResponse(provider: string, status: "sent" | "failed", response: JsonMap): JsonMap {
  if (provider === "sendgrid") return { status: response.status ?? null };
  if (provider === "dry-run") return { dryRun: true };
  if (provider === "unconfigured") return {};
  if (status === "sent") return {};
  return { provider, status };
}

function publicEmailResult(result: EmailResult): Omit<EmailResult, "response"> {
  return {
    status: result.status,
    provider: result.provider,
    providerMessageId: result.providerMessageId,
    error: result.error
  };
}

function isProviderUnconfigured(result: EmailResult): boolean {
  return result.status === "failed" && result.provider === "unconfigured";
}

function assertUuid(value: unknown, label: string): string {
  if (!isUuid(value)) throw new Error(`${label} is invalid.`);
  return value;
}

function assertAction(value: unknown): IntegrationAction {
  const actions: IntegrationAction[] = [
    "generate_quote_pdf",
    "generate_invoice_pdf",
    "get_quote_pdf_url",
    "get_internal_document_url",
    "create_upload_signed_url",
    "record_uploaded_document",
    "auto_route_public_rfq",
    "send_quote_email",
    "send_invoice_email"
  ];
  if (typeof value !== "string" || !actions.includes(value as IntegrationAction)) throw new Error("Unsupported action.");
  return value as IntegrationAction;
}

function assertStoragePath(path: unknown): string {
  if (typeof path !== "string" || !path || path.length > 500 || path.startsWith("/") || path.includes("..")) {
    throw new Error("Document path is invalid.");
  }
  return path;
}

function money(value: unknown, currency = "ZAR"): string {
  return new Intl.NumberFormat("en-ZA", { style: "currency", currency }).format(Number(value ?? 0));
}

function pdfEscape(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/\(/g, "\\(").replace(/\)/g, "\\)");
}

function buildPdf(title: string, lines: string[]): Uint8Array {
  const safeLines = [title, "", ...lines].map((line) => clean(line)).slice(0, 54);
  const content = [
    "BT",
    "/F1 18 Tf",
    "50 790 Td",
    `(${pdfEscape(title)}) Tj`,
    "/F1 10 Tf",
    "0 -28 Td",
    ...safeLines.slice(1).flatMap((line) => [`(${pdfEscape(line)}) Tj`, "0 -15 Td"]),
    "ET"
  ].join("\n");
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    `<< /Length ${content.length} >>\nstream\n${content}\nendstream`
  ];
  let body = "%PDF-1.4\n";
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(body.length);
    body += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xrefOffset = body.length;
  body += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (let index = 1; index <= objects.length; index += 1) {
    body += `${String(offsets[index]).padStart(10, "0")} 00000 n \n`;
  }
  body += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xrefOffset}\n%%EOF`;
  return new TextEncoder().encode(body);
}

function createUserClient(req: Request) {
  return createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: req.headers.get("authorization") ?? "" } }
  });
}

async function requireInternal(req: Request, permission: "manage_rfqs" | "view_all_quotes" = "manage_rfqs") {
  const userClient = createUserClient(req);
  const { data, error } = await userClient.rpc("ttaq_get_current_internal_user");
  if (error) throw new Error("Internal access could not be verified.");
  const user = Array.isArray(data) ? data[0] : data;
  if (!user || user.user_status !== "active") throw new Error("Active Time Trucking internal access is required.");
  const allowed = user.role === "owner"
    || (permission === "manage_rfqs" && user.can_manage_rfqs)
    || (permission === "view_all_quotes" && (user.can_view_all_quotes || user.can_manage_rfqs));
  if (!allowed) throw new Error("Your role is not allowed to perform this action.");
  return { user, userClient };
}

async function signedUrl(bucket: string, path: string, expiresIn = 900): Promise<string> {
  const { data, error } = await serviceClient.storage.from(bucket).createSignedUrl(path, expiresIn);
  if (error || !data?.signedUrl) throw new Error("Could not create a signed document URL.");
  return data.signedUrl;
}

async function uploadPdf(bucket: string, path: string, bytes: Uint8Array): Promise<void> {
  const { error } = await serviceClient.storage.from(bucket).upload(path, new Blob([bytes], { type: "application/pdf" }), {
    contentType: "application/pdf",
    upsert: true
  });
  if (error) throw new Error(error.message);
}

async function sendEmail(input: {
  to: string;
  subject: string;
  html: string;
  entityType: string;
  entityId: string;
  quoteRequestId?: string | null;
}): Promise<EmailResult> {
  if (!isEmail(input.to)) {
    return { status: "failed", provider: emailProvider || "unconfigured", providerMessageId: null, error: "Recipient email is invalid.", response: {} };
  }

  if (dryRunEmail) {
    return {
      status: "failed",
      provider: "dry-run",
      providerMessageId: null,
      error: "EMAIL_DRY_RUN is enabled. No email was delivered.",
      response: { dryRun: true }
    };
  }

  if (!emailProvider || !emailFrom) {
    return {
      status: "failed",
      provider: "unconfigured",
      providerMessageId: null,
      error: "Email provider or verified sender is not configured.",
      response: {}
    };
  }

  const from = `${emailFromName} <${emailFrom}>`;
  if (emailProvider === "resend") {
    const apiKey = Deno.env.get("RESEND_API_KEY");
    if (!apiKey) return { status: "failed", provider: "unconfigured", providerMessageId: null, error: "Email provider API key is not configured.", response: {} };
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ from, to: input.to, subject: input.subject, html: input.html })
    });
    const payload = await response.json().catch(() => ({}));
    return {
      status: response.ok ? "sent" : "failed",
      provider: "resend",
      providerMessageId: typeof payload.id === "string" ? payload.id : null,
      error: response.ok ? null : clean(payload.message, "Resend delivery failed."),
      response: payload
    };
  }

  if (emailProvider === "sendgrid") {
    const apiKey = Deno.env.get("SENDGRID_API_KEY");
    if (!apiKey) return { status: "failed", provider: "unconfigured", providerMessageId: null, error: "Email provider API key is not configured.", response: {} };
    const response = await fetch("https://api.sendgrid.com/v3/mail/send", {
      method: "POST",
      headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({
        personalizations: [{ to: [{ email: input.to }] }],
        from: { email: emailFrom, name: emailFromName },
        subject: input.subject,
        content: [{ type: "text/html", value: input.html }]
      })
    });
    return {
      status: response.ok ? "sent" : "failed",
      provider: "sendgrid",
      providerMessageId: response.headers.get("x-message-id"),
      error: response.ok ? null : "SendGrid delivery failed.",
      response: { status: response.status }
    };
  }

  if (emailProvider === "postmark") {
    const apiKey = Deno.env.get("POSTMARK_SERVER_TOKEN");
    if (!apiKey) return { status: "failed", provider: "unconfigured", providerMessageId: null, error: "Email provider API key is not configured.", response: {} };
    const response = await fetch("https://api.postmarkapp.com/email", {
      method: "POST",
      headers: { "X-Postmark-Server-Token": apiKey, "content-type": "application/json" },
      body: JSON.stringify({ From: from, To: input.to, Subject: input.subject, HtmlBody: input.html })
    });
    const payload = await response.json().catch(() => ({}));
    return {
      status: response.ok ? "sent" : "failed",
      provider: "postmark",
      providerMessageId: typeof payload.MessageID === "string" ? payload.MessageID : null,
      error: response.ok ? null : clean(payload.Message, "Postmark delivery failed."),
      response: payload
    };
  }

  return { status: "failed", provider: emailProvider, providerMessageId: null, error: `Unsupported email provider: ${emailProvider}`, response: {} };
}

async function logEmail(input: {
  quoteRequestId?: string | null;
  entityType: string;
  entityId: string;
  to: string;
  subject: string;
  result: EmailResult;
}) {
  const { error } = await serviceClient.from("email_logs").insert({
    quote_request_id: input.quoteRequestId ?? null,
    entity_type: input.entityType,
    entity_id: input.entityId,
    recipient_email: input.to,
    subject: input.subject,
    provider: input.result.provider,
    provider_message_id: input.result.providerMessageId,
    status: input.result.status,
    error_message: input.result.error,
    sent_at: input.result.status === "sent" ? new Date().toISOString() : null,
    provider_response: safeEmailProviderResponse(input.result.provider, input.result.status, input.result.response)
  });
  if (error) throw new IntegrationStageError("email_log_failed", error);
}

function googleMapsDirectionsUrl(addresses: string[]): string {
  const params = new URLSearchParams({
    api: "1",
    origin: addresses[0] ?? "",
    destination: addresses[addresses.length - 1] ?? "",
    travelmode: "driving"
  });
  const waypoints = addresses.slice(1, -1).filter(Boolean);
  if (waypoints.length) params.set("waypoints", waypoints.join("|"));
  return `https://www.google.com/maps/dir/?${params.toString()}`;
}

function secondsFromGoogleDuration(value: unknown): number {
  const match = String(value ?? "").match(/^([0-9.]+)s$/);
  return match ? Number(match[1]) : 0;
}

function coordinatePair(location: unknown): { latitude: number | null; longitude: number | null } {
  const latLng = (location as JsonMap | null)?.latLng as JsonMap | undefined;
  const latitude = Number(latLng?.latitude);
  const longitude = Number(latLng?.longitude);
  return {
    latitude: Number.isFinite(latitude) ? latitude : null,
    longitude: Number.isFinite(longitude) ? longitude : null
  };
}

function tollStatus(route: JsonMap): string {
  const tollInfo = (route.travelAdvisory as JsonMap | undefined)?.tollInfo as JsonMap | undefined;
  if (!tollInfo) return "unavailable";
  const prices = tollInfo.estimatedPrice ?? tollInfo.estimatedPrices;
  return Array.isArray(prices) && prices.length > 0 ? "available" : "expected_unknown";
}

async function applyRouteAutomation(input: {
  quoteRequestId: string;
  responseToken: string;
  publicReference: string;
  distanceKm: number;
  durationHours: number;
  googleMapsUrl: string | null;
  providerResponse: JsonMap;
  providerStatus: "success" | "failed";
  providerError?: string | null;
}) {
  const { error } = await serviceClient.rpc("ttaq_apply_google_route_automation", {
    target_quote_request_id: input.quoteRequestId,
    raw_response_token: input.responseToken,
    public_reference_value: input.publicReference,
    google_distance_km_value: input.distanceKm,
    google_duration_hours_value: input.durationHours,
    google_maps_url_value: input.googleMapsUrl,
    provider_response_value: input.providerResponse,
    provider_status_value: input.providerStatus,
    provider_error_value: input.providerError ?? null
  });
  if (error) throw error;
}

async function autoRoutePublicRfq(body: JsonMap) {
  const quoteRequestId = assertUuid(body.quoteRequestId, "Quote request id");
  const responseToken = clean(body.responseToken);
  const publicReference = clean(body.publicReference);
  if (!responseToken || !publicReference) throw new Error("A quote response token and public reference are required.");

  const { data: stops, error: stopsError } = await serviceClient
    .from("quote_stops")
    .select("stop_order,stop_type,address")
    .eq("quote_request_id", quoteRequestId)
    .order("stop_order", { ascending: true });
  if (stopsError) throw stopsError;
  const addresses = (stops ?? []).map((stop: JsonMap) => clean(stop.address)).filter(Boolean);
  if (addresses.length < 2) {
    const errorMessage = "At least one collection and one delivery address are required for automatic routing.";
    await applyRouteAutomation({
      quoteRequestId,
      responseToken,
      publicReference,
      distanceKm: 0,
      durationHours: 0,
      googleMapsUrl: null,
      providerResponse: { provider: "google_routes", method: "routes_api", error: errorMessage },
      providerStatus: "failed",
      providerError: errorMessage
    });
    return { status: "failed", error: errorMessage };
  }

  if (!googleRoutesApiKey) {
    const errorMessage = "GOOGLE_ROUTES_API_KEY is not configured for backend automatic routing.";
    await applyRouteAutomation({
      quoteRequestId,
      responseToken,
      publicReference,
      distanceKm: 0,
      durationHours: 0,
      googleMapsUrl: googleMapsDirectionsUrl(addresses),
      providerResponse: { provider: "google_routes", method: "routes_api", error: errorMessage },
      providerStatus: "failed",
      providerError: errorMessage
    });
    return { status: "failed", error: errorMessage };
  }

  const requestPayload = {
    origin: { address: addresses[0] },
    destination: { address: addresses[addresses.length - 1] },
    intermediates: addresses.slice(1, -1).map((address) => ({ address })),
    travelMode: "DRIVE",
    routingPreference: "TRAFFIC_UNAWARE",
    computeAlternativeRoutes: false,
    extraComputations: ["TOLLS"],
    polylineQuality: "OVERVIEW",
    units: "METRIC"
  };

  try {
    const response = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "X-Goog-Api-Key": googleRoutesApiKey,
        "X-Goog-FieldMask": [
          "routes.distanceMeters",
          "routes.duration",
          "routes.legs.distanceMeters",
          "routes.legs.duration",
          "routes.legs.startLocation",
          "routes.legs.endLocation",
          "routes.polyline.encodedPolyline",
          "routes.travelAdvisory.tollInfo",
          "routes.warnings"
        ].join(",")
      },
      body: JSON.stringify(requestPayload)
    });
    const payload = await response.json().catch(() => ({})) as JsonMap;
    if (!response.ok) throw new Error(clean(payload.error && (payload.error as JsonMap).message, `Google Routes request failed with status ${response.status}.`));
    const route = Array.isArray(payload.routes) ? payload.routes[0] as JsonMap : null;
    if (!route) throw new Error("Google Routes returned no route.");
    const legs = Array.isArray(route.legs) ? route.legs as JsonMap[] : [];
    const distanceMeters = Number(route.distanceMeters ?? legs.reduce((sum, leg) => sum + Number(leg.distanceMeters ?? 0), 0));
    const durationSeconds = secondsFromGoogleDuration(route.duration) || legs.reduce((sum, leg) => sum + secondsFromGoogleDuration(leg.duration), 0);
    if (!Number.isFinite(distanceMeters) || distanceMeters <= 0) throw new Error("Google Routes returned a zero-distance route.");
    const stopSummaries = addresses.map((address, index) => {
      const sourceLeg = index === 0 ? legs[0] : legs[index - 1];
      const location = index === 0 ? sourceLeg?.startLocation : sourceLeg?.endLocation;
      return {
        stop_order: index + 1,
        address,
        formatted_address: address,
        place_id: null,
        ...coordinatePair(location)
      };
    });
    const providerResponse = {
      provider: "google_routes",
      method: "routes_api",
      leg_count: legs.length,
      legs: legs.map((leg, index) => ({
        leg: index + 1,
        origin: addresses[index],
        destination: addresses[index + 1],
        distance_km: Number((Number(leg.distanceMeters ?? 0) / 1000).toFixed(2)),
        duration_hours: Number((secondsFromGoogleDuration(leg.duration) / 3600).toFixed(2)),
        status: "OK"
      })),
      stops: stopSummaries,
      overview_polyline: (route.polyline as JsonMap | undefined)?.encodedPolyline ?? null,
      toll_status: tollStatus(route),
      toll_info: (route.travelAdvisory as JsonMap | undefined)?.tollInfo ?? null,
      route_risk_status: "default_or_manual",
      warnings: route.warnings ?? [],
      calculated_at: new Date().toISOString()
    };
    const distanceKm = Number((distanceMeters / 1000).toFixed(2));
    const durationHours = Number((durationSeconds / 3600).toFixed(2));
    await applyRouteAutomation({
      quoteRequestId,
      responseToken,
      publicReference,
      distanceKm,
      durationHours,
      googleMapsUrl: googleMapsDirectionsUrl(addresses),
      providerResponse,
      providerStatus: "success"
    });
    return { status: "success", distanceKm, durationHours };
  } catch (error) {
    const errorMessageValue = errorMessage(error, "Google Routes route calculation failed.");
    await applyRouteAutomation({
      quoteRequestId,
      responseToken,
      publicReference,
      distanceKm: 0,
      durationHours: 0,
      googleMapsUrl: googleMapsDirectionsUrl(addresses),
      providerResponse: {
        provider: "google_routes",
        method: "routes_api",
        request: { stop_count: addresses.length },
        error: errorMessageValue,
        calculated_at: new Date().toISOString()
      },
      providerStatus: "failed",
      providerError: errorMessageValue
    });
    return { status: "failed", error: errorMessageValue };
  }
}

async function generateQuotePdf(req: Request, quoteRequestId: string) {
  const { userClient } = await requireInternal(req, "manage_rfqs");
  assertUuid(quoteRequestId, "Quote request id");
  const { data: documentId, error } = await userClient.rpc("ttaq_generate_quote_document", { quote_request_id: quoteRequestId });
  if (error) throw error;
  const { data: doc, error: docError } = await serviceClient.from("quote_documents").select("*").eq("id", documentId).single();
  if (docError) throw docError;
  const payload = doc.customer_payload ?? {};
  const customer = payload.customer ?? {};
  const route = payload.route_estimate ?? {};
  const transport = payload.transport ?? {};
  const pricing = payload.pricing ?? {};
  const stops = Array.isArray(payload.stops) ? payload.stops : [];
  const cargo = Array.isArray(payload.cargo_items) ? payload.cargo_items : [];
  const terms = Array.isArray(payload.brand?.terms) ? payload.brand.terms : [];
  const lines = [
    "TIME TRUCKING - Safe. Reliable. On Time.",
    `Quote: ${doc.quote_number} / ${doc.public_reference}`,
    `Issue date: ${doc.quote_date}    Valid until: ${doc.validity_date}`,
    `Customer: ${clean(customer.company_name)} - ${clean(customer.contact_person)}`,
    `Email: ${clean(customer.email)}    Phone: ${clean(customer.phone)}`,
    `Route: ${clean(route.origin_address)} to ${clean(route.destination_address)}`,
    `Distance/duration: ${clean(route.total_distance_km, "0")} km / ${clean(route.total_duration_hours, "0")} hours`,
    `Vehicle/trailer: ${clean(transport.recommended_vehicle_type, "To be confirmed")} / ${clean(transport.recommended_trailer_type, "To be confirmed")}`,
    "Stops:",
    ...stops.map((stop: JsonMap) => `  ${clean(stop.stop_order)}. ${clean(stop.stop_type)} - ${clean(stop.address)}`),
    "Cargo:",
    ...cargo.map((item: JsonMap) => `  ${clean(item.description, "Cargo")} - ${clean(item.quantity, "1")} item(s)`),
    `Subtotal: ${money(Number(pricing.final_selling_price ?? doc.final_selling_price) - Number(pricing.vat_amount ?? doc.vat_amount), doc.currency)}`,
    `VAT: ${money(pricing.vat_amount ?? doc.vat_amount, doc.currency)}`,
    `Total: ${money(pricing.final_selling_price ?? doc.final_selling_price, doc.currency)}`,
    "Acceptance: open the secure quote link and accept or decline online.",
    "Terms:",
    ...terms.map((term: unknown) => `  ${clean(term)}`),
    "Contact: info@timetrucking.co.za"
  ];
  const pdf = buildPdf(`Time Trucking Quote ${doc.quote_number}`, lines);
  const path = `quotes/${doc.quote_request_id}/${safeFileName(doc.quote_number)}-v${doc.version_number}.pdf`;
  await uploadPdf("quote-documents", path, pdf);
  await serviceClient.from("quote_documents").update({
    pdf_storage_path: path,
    pdf_url: null,
    generated_at: new Date().toISOString(),
    generated_by: doc.generated_by ?? null
  }).eq("id", doc.id);
  const url = await signedUrl("quote-documents", path);
  return { quoteDocumentId: doc.id, storagePath: path, signedUrl: url };
}

async function generateInvoicePdf(req: Request, invoiceId: string) {
  await requireInternal(req, "manage_rfqs");
  assertUuid(invoiceId, "Invoice id");
  const { data: invoice, error } = await serviceClient
    .from("invoices")
    .select("*, invoice_line_items(*), invoice_payments(*)")
    .eq("id", invoiceId)
    .single();
  if (error) throw error;
  const lines = [
    "TIME TRUCKING - Safe. Reliable. On Time.",
    `Invoice: ${invoice.invoice_number}`,
    `Invoice date: ${invoice.invoice_date}    Due date: ${clean(invoice.due_date, "Pending")}`,
    `Customer: ${invoice.company_name} - ${clean(invoice.contact_person)}`,
    `Linked job/reference: ${clean(invoice.customer_payload?.job_number)} / ${clean(invoice.customer_payload?.public_reference)}`,
    "Line items:",
    ...(invoice.invoice_line_items ?? []).map((line: JsonMap) => `  ${clean(line.description)} - ${clean(line.quantity)} x ${money(line.unit_price, invoice.currency)} = ${money(line.line_total, invoice.currency)}`),
    `Subtotal: ${money(invoice.subtotal, invoice.currency)}`,
    `VAT: ${money(invoice.vat_amount, invoice.currency)}`,
    `Total: ${money(invoice.total_amount, invoice.currency)}`,
    `Paid: ${money(invoice.amount_paid, invoice.currency)}`,
    `Outstanding: ${money(invoice.balance_due, invoice.currency)}`,
    "Payment instructions: use the banking details configured in Time Trucking settings.",
    "Contact: info@timetrucking.co.za"
  ];
  const pdf = buildPdf(`Time Trucking Invoice ${invoice.invoice_number}`, lines);
  const path = `invoices/${invoice.id}/${safeFileName(invoice.invoice_number)}.pdf`;
  await uploadPdf("operational-documents", path, pdf);
  await serviceClient.from("invoices").update({
    pdf_storage_path: path,
    pdf_generated_at: new Date().toISOString()
  }).eq("id", invoice.id);
  const url = await signedUrl("operational-documents", path);
  return { invoiceId: invoice.id, storagePath: path, signedUrl: url };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "Method not allowed." });
  if (!supabaseUrl || !serviceRoleKey || !anonKey) return json(req, 500, { error: "Supabase Edge Function secrets are not configured." });

  try {
    const body = await req.json();
    const action = assertAction(body.action);

    if (action === "generate_quote_pdf") {
      return json(req, 200, await generateQuotePdf(req, assertUuid(body.quoteRequestId, "Quote request id")));
    }

    if (action === "generate_invoice_pdf") {
      return json(req, 200, await generateInvoicePdf(req, assertUuid(body.invoiceId, "Invoice id")));
    }

    if (action === "get_quote_pdf_url") {
      const token = body.rawToken ? String(body.rawToken) : body.token ? String(body.token) : null;
      const reference = body.reference ? String(body.reference) : null;
      if (!token && !reference) throw new Error("A secure quote token or reference is required.");
      const { data, error } = await serviceClient.rpc("ttaq_get_public_quote_document", {
        raw_response_token: token,
        public_reference_value: reference
      });
      if (error) throw error;
      const doc = Array.isArray(data) ? data[0] : data;
      if (!doc?.quote_document_id) throw new Error("Quote document is not available for this secure link.");
      const { data: stored, error: storedError } = await serviceClient.from("quote_documents").select("pdf_storage_path").eq("id", doc.quote_document_id).single();
      if (storedError) throw storedError;
      if (!stored?.pdf_storage_path) throw new Error("Quote PDF has not been generated yet.");
      return json(req, 200, { signedUrl: await signedUrl("quote-documents", assertStoragePath(stored.pdf_storage_path)), expiresIn: 900 });
    }

    if (action === "get_internal_document_url") {
      await requireInternal(req, "view_all_quotes");
      const bucket = String(body.bucket ?? "");
      const path = assertStoragePath(body.path);
      if (!["quote-documents", "operational-documents"].includes(bucket)) throw new Error("Unsupported document request.");
      return json(req, 200, { signedUrl: await signedUrl(bucket, path), expiresIn: 900 });
    }

    if (action === "create_upload_signed_url") {
      await requireInternal(req, "view_all_quotes");
      const entityType = String(body.entityType ?? "document");
      if (!["fuel_slip", "transport_job"].includes(entityType)) throw new Error("Unsupported upload target.");
      const entityId = assertUuid(body.entityId, "Upload entity id");
      const filename = safeFileName(String(body.filename ?? "upload.bin"));
      const contentType = String(body.contentType ?? "");
      const size = Number(body.size ?? 0);
      const allowed = ["application/pdf", "image/jpeg", "image/png", "image/webp"];
      if (!allowed.includes(contentType)) throw new Error("Unsupported file type. Use PDF, JPEG, PNG, or WEBP.");
      if (!Number.isFinite(size) || size <= 0 || size > 15 * 1024 * 1024) throw new Error("File must be 15MB or smaller.");
      const path = `${safeFileName(entityType)}/${entityId}/${Date.now()}-${filename}`;
      const { data, error } = await serviceClient.storage.from("operational-documents").createSignedUploadUrl(path);
      if (error) throw error;
      return json(req, 200, { bucket: "operational-documents", path, token: data.token, signedUrl: data.signedUrl });
    }

    if (action === "record_uploaded_document") {
      const { userClient } = await requireInternal(req, "view_all_quotes");
      const { data, error } = await userClient.rpc("ttaq_record_document_uploaded", {
        target_entity_type: String(body.entityType ?? ""),
        target_entity_id: assertUuid(body.entityId, "Upload entity id"),
        storage_path_value: assertStoragePath(body.storagePath),
        document_name_value: String(body.documentName ?? ""),
        content_type_value: body.contentType ? String(body.contentType) : null,
        file_size_bytes_value: body.size ? Number(body.size) : null,
        customer_safe_value: Boolean(body.customerSafe)
      });
      if (error) throw error;
      return json(req, 200, { documentId: data });
    }

    if (action === "auto_route_public_rfq") {
      return json(req, 200, await autoRoutePublicRfq(body));
    }

    if (action === "send_quote_email") {
      const docId = await atStage("validate_request", async () => assertUuid(body.quoteDocumentId, "Quote document id"));
      const { userClient } = await atStage("authenticate_internal_user", () => requireInternal(req, "manage_rfqs"));
      const doc = await atStage("document_lookup_failed", async () => {
        const { data: docResult, error } = await userClient.rpc("ttaq_get_internal_quote_document", {
          target_quote_document_id: docId,
          target_quote_request_id: null
        });
        if (error) throw error;
        const documentRecord = Array.isArray(docResult) ? docResult[0] : docResult;
        if (!documentRecord) throw new Error("Quote document not found.");
        if (documentRecord.email_status === "sent" && !body.forceResend) throw new Error("Quote email was already sent. Use an explicit resend action.");
        return documentRecord;
      });
      let path = doc.pdf_storage_path as string | null;
      if (!path) {
        const generated = await atStage("quote_pdf_generate_failed", () => generateQuotePdf(req, doc.quote_request_id));
        path = generated.storagePath;
      }
      const pdfUrl = await atStage("quote_pdf_signed_url_failed", () => signedUrl("quote-documents", path));
      const { customer, quoteLink, subject, to } = await atStage("customer_quote_link_failed", async () => {
        const customerRecord = doc.customer_payload?.customer ?? {};
        const customerEmail = String(customerRecord.email ?? "");
        if (!isEmail(customerEmail)) throw new Error("Customer email is missing or invalid.");
        if (body.to && String(body.to).toLowerCase() !== customerEmail.toLowerCase()) throw new Error("Quote emails can only be sent to the customer email on the quote.");
        const publicReference = clean(doc.public_reference);
        if (!publicReference) throw new Error("Quote public reference is missing.");
        return {
          customer: customerRecord,
          quoteLink: appPublicUrl ? `${appPublicUrl}/quote-view.html?ref=${encodeURIComponent(publicReference)}` : `quote-view.html?ref=${encodeURIComponent(publicReference)}`,
          subject: `Time Trucking quote ${doc.quote_number}`,
          to: customerEmail
        };
      });
      const result = await atStage("email_provider_failed", () => sendEmail({
        to,
        subject,
        entityType: "quote_document",
        entityId: doc.quote_document_id,
        quoteRequestId: doc.quote_request_id,
        html: `<p>Hello ${clean(customer.contact_person, "there")},</p><p>Your Time Trucking quote <strong>${doc.quote_number}</strong> is ready.</p><p>Total: <strong>${money(doc.final_selling_price, doc.currency)}</strong></p><p><a href="${quoteLink}">View and respond to your quote</a></p><p><a href="${pdfUrl}">Download PDF quote</a></p><p>Safe. Reliable. On Time.</p>`
      }));
      await atStage("email_log_failed", () => logEmail({ quoteRequestId: doc.quote_request_id, entityType: "quote_document", entityId: doc.quote_document_id, to, subject, result }));
      if (result.status === "failed" && !isProviderUnconfigured(result)) {
        throw new IntegrationStageError("email_provider_failed", result.error ?? "Email provider delivery failed.");
      }
      await atStage("quote_mark_sent_failed", async () => {
        const { error } = await userClient.rpc("ttaq_mark_quote_document_sent", {
          target_quote_document_id: doc.quote_document_id,
          email_sent_to_value: to,
          email_status_value: result.status,
          email_error_value: result.error
        });
        if (error) throw error;
      });
      const payload = await atStage("return_response_failed", async () => ({
        ...publicEmailResult(result),
        stage: "send_quote_email_complete",
        quoteLink,
        appPublicUrlConfigured: Boolean(appPublicUrl),
        productionConfigWarning: appPublicUrl ? null : "APP_PUBLIC_URL must be configured before production launch so emailed links use the deployed Time Trucking Auto-Quote URL."
      }));
      return json(req, 200, payload);
    }

    if (action === "send_invoice_email") {
      await requireInternal(req, "manage_rfqs");
      const invoiceId = assertUuid(body.invoiceId, "Invoice id");
      const { data: invoice, error } = await serviceClient.from("invoices").select("*").eq("id", invoiceId).single();
      if (error) throw error;
      if (invoice.email_status === "sent" && !body.forceResend) throw new Error("Invoice email was already sent. Use an explicit resend action.");
      let path = invoice.pdf_storage_path as string | null;
      if (!path) {
        const generated = await generateInvoicePdf(req, invoiceId);
        path = generated.storagePath;
      }
      const pdfUrl = await signedUrl("operational-documents", path);
      const to = String(invoice.email ?? "");
      if (body.to && String(body.to).toLowerCase() !== to.toLowerCase()) throw new Error("Invoice emails can only be sent to the customer email on the invoice.");
      const subject = `Time Trucking invoice ${invoice.invoice_number}`;
      const result = await sendEmail({
        to,
        subject,
        entityType: "invoice",
        entityId: invoice.id,
        quoteRequestId: invoice.quote_request_id,
        html: `<p>Hello ${clean(invoice.contact_person, "there")},</p><p>Your Time Trucking invoice <strong>${invoice.invoice_number}</strong> is ready.</p><p>Total: <strong>${money(invoice.total_amount, invoice.currency)}</strong></p><p>Outstanding: <strong>${money(invoice.balance_due, invoice.currency)}</strong></p><p><a href="${pdfUrl}">Download PDF invoice</a></p><p>Safe. Reliable. On Time.</p>`
      });
      await logEmail({ quoteRequestId: invoice.quote_request_id, entityType: "invoice", entityId: invoice.id, to, subject, result });
      await serviceClient.from("invoices").update({
        sent_at: result.status === "sent" ? new Date().toISOString() : invoice.sent_at,
        email_sent_to: to,
        email_status: result.status,
        email_error: result.error,
        provider_message_id: result.providerMessageId
      }).eq("id", invoice.id);
      return json(req, 200, result);
    }

    throw new Error(`Unsupported action: ${action}`);
  } catch (error) {
    console.error(error);
    return json(req, 400, {
      error: errorMessage(error),
      stage: error instanceof IntegrationStageError ? error.stage : "unhandled_error"
    });
  }
});
