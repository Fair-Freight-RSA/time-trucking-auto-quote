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
  | "invite_internal_user"
  | "get_quote_pdf_url"
  | "get_internal_document_url"
  | "create_upload_signed_url"
  | "record_uploaded_document"
  | "auto_route_public_rfq"
  | "diesel_scheduler_status"
  | "install_diesel_scheduler"
  | "install_toll_scheduler"
  | "refresh_official_diesel"
  | "refresh_official_tolls"
  | "trigger_diesel_scheduler_once"
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
const dieselRefreshSecret = Deno.env.get("DIESEL_REFRESH_SECRET") ?? "";
const dmprFuelPricesUrl = Deno.env.get("DMPR_FUEL_PRICES_URL") ?? "https://www.dmpr.gov.za/Services/Petroleum-Resources/Fuel-Prices";

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
    "invite_internal_user",
    "get_quote_pdf_url",
    "get_internal_document_url",
    "create_upload_signed_url",
    "record_uploaded_document",
    "auto_route_public_rfq",
    "diesel_scheduler_status",
    "install_diesel_scheduler",
    "install_toll_scheduler",
    "refresh_official_diesel",
    "refresh_official_tolls",
    "trigger_diesel_scheduler_once",
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

async function requireInternalUserManagement(req: Request) {
  const userClient = createUserClient(req);
  const { data, error } = await userClient.rpc("ttaq_get_current_internal_user");
  if (error) throw new Error("Internal access could not be verified.");
  const user = Array.isArray(data) ? data[0] : data;
  if (!user || user.user_status !== "active") throw new Error("Active Time Trucking internal access is required.");
  if (user.role !== "owner" && !user.can_manage_users) throw new Error("Your role is not allowed to invite users.");
  return { user, userClient };
}

function rolePermissions(role: string, overrides: JsonMap | undefined = {}): JsonMap {
  const defaults: Record<string, JsonMap> = {
    owner: {
      can_view_all_quotes: true,
      can_manage_rfqs: true,
      can_approve_quotes: true,
      can_adjust_pricing: true,
      can_manage_pricing_rules: true,
      can_manage_users: true
    },
    manager: {
      can_view_all_quotes: true,
      can_manage_rfqs: true,
      can_approve_quotes: true,
      can_adjust_pricing: false,
      can_manage_pricing_rules: false,
      can_manage_users: false
    },
    staff: {
      can_view_all_quotes: false,
      can_manage_rfqs: true,
      can_approve_quotes: false,
      can_adjust_pricing: false,
      can_manage_pricing_rules: false,
      can_manage_users: false
    },
    viewer: {
      can_view_all_quotes: true,
      can_manage_rfqs: false,
      can_approve_quotes: false,
      can_adjust_pricing: false,
      can_manage_pricing_rules: false,
      can_manage_users: false
    }
  };
  return { ...(defaults[role] ?? defaults.viewer), ...overrides };
}

async function inviteInternalUser(req: Request, body: JsonMap): Promise<JsonMap> {
  const { user } = await requireInternalUserManagement(req);
  const email = clean(body.email).toLowerCase();
  const fullName = clean(body.fullName ?? body.full_name);
  const phone = clean(body.phone);
  const role = clean(body.role, "viewer");
  if (!isEmail(email)) throw new Error("Enter a valid email address.");
  if (!["owner", "manager", "staff", "viewer"].includes(role)) throw new Error("Choose a valid Time Trucking role.");
  if (role === "owner" && user.role !== "owner") throw new Error("Only an owner can invite another owner.");
  const permissions = rolePermissions(role, body.permissions as JsonMap | undefined);
  const redirectTo = appPublicUrl ? `${appPublicUrl}/login.html` : undefined;

  const { data: invitationRecord, error: invitationError } = await serviceClient
    .from("internal_user_invitations")
    .insert({
      email,
      full_name: fullName || null,
      phone: phone || null,
      role,
      permissions,
      invitation_status: "pending",
      invited_by: user.id,
      last_sent_at: new Date().toISOString()
    })
    .select("*")
    .single();
  if (invitationError) throw new Error("Could not record the user invitation.");

  try {
    const { data, error } = await serviceClient.auth.admin.inviteUserByEmail(email, {
      redirectTo,
      data: {
        full_name: fullName,
        time_trucking_role: role
      }
    });
    if (error) throw error;
    const authUserId = data.user?.id;
    if (!authUserId) throw new Error("Supabase did not return the invited user id.");

    const { error: profileError } = await serviceClient.from("internal_users").upsert({
      id: authUserId,
      email,
      full_name: fullName || null,
      role,
      user_status: "active",
      can_view_all_quotes: Boolean(permissions.can_view_all_quotes),
      can_manage_rfqs: Boolean(permissions.can_manage_rfqs),
      can_approve_quotes: Boolean(permissions.can_approve_quotes),
      can_adjust_pricing: Boolean(permissions.can_adjust_pricing),
      can_manage_pricing_rules: Boolean(permissions.can_manage_pricing_rules),
      can_manage_users: Boolean(permissions.can_manage_users),
      invited_by: user.id,
      invited_at: new Date().toISOString(),
      revoked_at: null
    });
    if (profileError) throw profileError;

    await serviceClient
      .from("internal_user_invitations")
      .update({ invitation_status: "sent", auth_user_id: authUserId, last_error: null })
      .eq("id", invitationRecord.id);

    return {
      status: "sent",
      email,
      role,
      authUserLinked: true,
      message: "Invitation sent and Time Trucking access record linked automatically."
    };
  } catch (error) {
    await serviceClient
      .from("internal_user_invitations")
      .update({ invitation_status: "failed", last_error: errorMessage(error) })
      .eq("id", invitationRecord.id);
    throw new Error("Invitation could not be sent. Check the email address and Supabase Auth email settings.");
  }
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

type Coordinate = { latitude: number; longitude: number };

function decodePolyline(polyline: string): Coordinate[] {
  const points: Coordinate[] = [];
  let index = 0;
  let latitude = 0;
  let longitude = 0;
  while (index < polyline.length) {
    let result = 0;
    let shift = 0;
    let byte = 0;
    do {
      byte = polyline.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20 && index < polyline.length);
    latitude += (result & 1) ? ~(result >> 1) : (result >> 1);

    result = 0;
    shift = 0;
    do {
      byte = polyline.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20 && index < polyline.length);
    longitude += (result & 1) ? ~(result >> 1) : (result >> 1);
    points.push({ latitude: latitude / 1e5, longitude: longitude / 1e5 });
  }
  return points;
}

function toRadians(value: number): number {
  return value * Math.PI / 180;
}

function metersBetween(a: Coordinate, b: Coordinate): number {
  const earthRadius = 6371000;
  const dLat = toRadians(b.latitude - a.latitude);
  const dLon = toRadians(b.longitude - a.longitude);
  const lat1 = toRadians(a.latitude);
  const lat2 = toRadians(b.latitude);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * earthRadius * Math.asin(Math.sqrt(h));
}

function distanceToSegmentMeters(point: Coordinate, a: Coordinate, b: Coordinate): number {
  const latScale = 111320;
  const lonScale = 111320 * Math.cos(toRadians((a.latitude + b.latitude) / 2));
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

async function matchOfficialTollPlazas(polyline: string | null): Promise<JsonMap> {
  if (!polyline) {
    return { status: "unknown", reason: "Google route polyline unavailable", matches: [] };
  }
  const route = decodePolyline(polyline);
  if (route.length < 2) {
    return { status: "unknown", reason: "Google route polyline could not be decoded", matches: [] };
  }
  const { data, error } = await serviceClient
    .from("toll_plazas")
    .select("id,plaza_name,road_route,operator_key,latitude,longitude,plaza_type,direction,route_match_strategy,coordinate_confidence")
    .eq("is_active", true)
    .limit(1000);
  if (error) throw error;
  const matches: JsonMap[] = [];
  const routeReadyCoordinateConfidence = new Set(["operator_published", "verified_route_geometry", "verified_map_source"]);
  for (const plaza of data ?? []) {
    if (!routeReadyCoordinateConfidence.has(String(plaza.coordinate_confidence ?? "review_required"))) continue;
    if (plaza.latitude === null || plaza.longitude === null) continue;
    const point = { latitude: Number(plaza.latitude), longitude: Number(plaza.longitude) };
    if (!Number.isFinite(point.latitude) || !Number.isFinite(point.longitude)) continue;
    let bestDistance = Number.POSITIVE_INFINITY;
    let bestSegment = 0;
    for (let index = 0; index < route.length - 1; index += 1) {
      const distance = distanceToSegmentMeters(point, route[index], route[index + 1]);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestSegment = index;
      }
    }
    const thresholdMeters = plaza.plaza_type === "ramp" ? 180 : 900;
    if (bestDistance <= thresholdMeters) {
      const confidenceRatio = Math.max(0, 1 - (bestDistance / thresholdMeters));
      if (plaza.plaza_type === "ramp" && confidenceRatio < 0.72) continue;
      matches.push({
        plaza_id: plaza.id,
        plaza_name: plaza.plaza_name,
        road_route: plaza.road_route,
        operator_key: plaza.operator_key,
        plaza_type: plaza.plaza_type,
        distance_m: Number(bestDistance.toFixed(1)),
        match_confidence: confidenceRatio >= 0.75 ? "high" : confidenceRatio >= 0.45 ? "standard" : "low_review",
        route_segment_index: bestSegment,
        route_order: bestSegment,
        direction: plaza.direction ?? null,
        match_threshold_m: thresholdMeters,
        route_match_strategy: plaza.route_match_strategy ?? (plaza.plaza_type === "ramp" ? "strict_ramp_geometry_threshold" : "mainline_geometry_threshold"),
        coordinate_confidence: plaza.coordinate_confidence ?? "review_required"
      });
    }
  }
  matches.sort((left, right) => Number(left.route_segment_index ?? 0) - Number(right.route_segment_index ?? 0) || Number(left.distance_m ?? 0) - Number(right.distance_m ?? 0));
  const deduped = [...new Map(matches.map((match) => [String(match.plaza_id), match])).values()];
  return {
    status: "matched",
    method: "google_overview_polyline_to_official_plaza_coordinates",
    route_point_count: route.length,
    match_threshold_note: "Mainline plazas use 900m against route geometry. Ramp plazas use a strict 180m threshold plus confidence gating so passing mainline traffic does not accidentally trigger ramp tolls.",
    matches: deduped
  };
}

function sampledRoutePoints(polyline: string | null): JsonMap[] {
  if (!polyline) return [];
  const points = decodePolyline(polyline);
  if (points.length <= 160) {
    return points.map((point, index) => ({
      point_index: index,
      latitude: Number(point.latitude.toFixed(6)),
      longitude: Number(point.longitude.toFixed(6))
    }));
  }
  const step = Math.ceil(points.length / 160);
  const sampled = points.filter((_, index) => index % step === 0);
  const last = points[points.length - 1];
  if (sampled[sampled.length - 1] !== last) sampled.push(last);
  return sampled.map((point, index) => ({
    point_index: index,
    latitude: Number(point.latitude.toFixed(6)),
    longitude: Number(point.longitude.toFixed(6))
  }));
}

function tollStatus(route: JsonMap): string {
  const tollInfo = (route.travelAdvisory as JsonMap | undefined)?.tollInfo as JsonMap | undefined;
  if (!tollInfo) return "unavailable";
  const prices = tollInfo.estimatedPrice ?? tollInfo.estimatedPrices;
  return Array.isArray(prices) && prices.length > 0 ? "available" : "expected_unknown";
}

function normalizeWhitespace(value: string): string {
  return value.replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();
}

function decodeHtml(value: string): string {
  return value
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ");
}

function monthNumber(month: string): number {
  const months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];
  return months.indexOf(month.toLowerCase()) + 1;
}

function parseEffectiveDate(text: string): string | null {
  const match = text.match(/effective\s+(?:from\s+)?(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})/i);
  if (!match) return null;
  const month = monthNumber(match[2]);
  if (!month) return null;
  return `${match[3]}-${String(month).padStart(2, "0")}-${String(Number(match[1])).padStart(2, "0")}`;
}

function absoluteUrl(href: string, baseUrl: string): string {
  try {
    return new URL(decodeHtml(href), baseUrl).toString();
  } catch {
    return decodeHtml(href);
  }
}

function latestDmprPublication(pageHtml: string): { title: string; href: string; effectiveDate: string | null } {
  const sectionMatch = pageHtml.match(/<h3[^>]*>\s*(Fuel Prices Effective from [^<]+)<\/h3>[\s\S]{0,2500}?<h4[^>]*>\s*([^<]+)\s*<\/h4>[\s\S]{0,1200}?<a\b[^>]*href=["']([^"']+)["']/i);
  if (sectionMatch) {
    const heading = normalizeWhitespace(decodeHtml(sectionMatch[1]));
    const documentTitle = normalizeWhitespace(decodeHtml(sectionMatch[2]));
    return {
      title: `${heading} - ${documentTitle}`,
      href: decodeHtml(sectionMatch[3]),
      effectiveDate: parseEffectiveDate(heading)
    };
  }
  const anchors = [...pageHtml.matchAll(/<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi)]
    .map((match) => ({
      href: decodeHtml(match[1]),
      title: normalizeWhitespace(decodeHtml(match[2].replace(/<[^>]+>/g, " ")))
    }))
    .filter((anchor) => /fuel prices?/i.test(anchor.title) && /effective/i.test(anchor.title));
  const latest = anchors[0];
  if (!latest) throw new Error("DMPR fuel price publication link was not found.");
  return { ...latest, effectiveDate: parseEffectiveDate(latest.title) };
}

function plausibleDieselPrice(value: number): boolean {
  return Number.isFinite(value) && value >= 5 && value <= 35;
}

function centsToRand(value: number): number {
  return Number((value / 100).toFixed(4));
}

function parseDieselPricesFromText(text: string): Array<{ grade: "diesel_500ppm" | "diesel_50ppm"; pricePerLitre: number; rawValue: number; unit: string; evidence: string }> {
  const rowResults: Array<{ grade: "diesel_500ppm" | "diesel_50ppm"; pricePerLitre: number; rawValue: number; unit: string; evidence: string }> = [];
  let currentGrade: "diesel_500ppm" | "diesel_50ppm" | null = null;
  for (const line of text.split(/\r?\n/).map((row) => normalizeWhitespace(row)).filter(Boolean)) {
    if (/Diesel\s+0\.005%\s+sul(?:f|ph)ur/i.test(line)) currentGrade = "diesel_50ppm";
    if (/Diesel\s+0\.05%\s+sul(?:f|ph)ur/i.test(line)) currentGrade = "diesel_500ppm";
    if (!currentGrade || !/^1A\s*\|/i.test(line)) continue;
    const columns = line.split("|").map((value) => normalizeWhitespace(value));
    const raw = Number((columns[1] ?? "").replace(",", "."));
    const price = centsToRand(raw);
    if (plausibleDieselPrice(price) && !rowResults.some((result) => result.grade === currentGrade)) {
      rowResults.push({
        grade: currentGrade,
        pricePerLitre: price,
        rawValue: raw,
        unit: "c/L",
        evidence: `DMPR fuel price schedule basic list price row 1A: ${line}`
      });
    }
  }
  if (rowResults.length) return rowResults;

  const normalized = normalizeWhitespace(text);
  const results: Array<{ grade: "diesel_500ppm" | "diesel_50ppm"; pricePerLitre: number; rawValue: number; unit: string; evidence: string }> = [];

  for (const target of [
    { grade: "diesel_500ppm" as const, pattern: /Diesel\s+0\.05%\s+sul(?:f|ph)ur/i },
    { grade: "diesel_50ppm" as const, pattern: /Diesel\s+0\.005%\s+sul(?:f|ph)ur/i }
  ]) {
    const gradeMatch = target.pattern.exec(normalized);
    if (!gradeMatch) continue;
    const section = normalized.slice(gradeMatch.index, gradeMatch.index + 2200);
    const zoneOneMatch = section.match(/\b1A\b\s+([0-9]{4}(?:[.,][0-9]+)?)\s+[0-9]{1,3}(?:[.,][0-9]+)?\s+([0-9]{4}(?:[.,][0-9]+)?)/i);
    if (!zoneOneMatch) continue;
    const raw = Number(zoneOneMatch[1].replace(",", "."));
    const price = centsToRand(raw);
    if (plausibleDieselPrice(price)) {
      results.push({
        grade: target.grade,
        pricePerLitre: price,
        rawValue: raw,
        unit: "c/L",
        evidence: `DMPR fuel price schedule basic list price for ${target.grade}; zone 1A row also lists wholesale ${zoneOneMatch[2]} c/L.`
      });
    }
  }

  if (results.length) return results;

  const windows = normalized.match(/.{0,140}diesel.{0,260}/gi) ?? [];
  for (const window of windows) {
    const grade = /0\.005|50\s*ppm/i.test(window)
      ? "diesel_50ppm"
      : /0\.05|500\s*ppm/i.test(window)
        ? "diesel_500ppm"
        : null;
    if (!grade) continue;
    const matches = [...window.matchAll(/(?:R\s*)?([0-9]{1,2}(?:[.,][0-9]{1,4})|[0-9]{3,4}(?:[.,][0-9]{1,2})?)\s*(c\/?l|cents?\s*\/?\s*l(?:itre)?|rand\s*\/?\s*l(?:itre)?|r\/?l)?/gi)];
    for (const match of matches) {
      const raw = Number(match[1].replace(",", "."));
      const unit = normalizeWhitespace(match[2] ?? "");
      if (!unit && raw <= 100) continue;
      const price = /c\/?l|cent/i.test(unit) || raw > 100 ? centsToRand(raw) : raw;
      if (plausibleDieselPrice(price)) {
        results.push({ grade, pricePerLitre: price, rawValue: raw, unit: unit || (raw > 100 ? "c/L" : "R/L"), evidence: window.slice(0, 300) });
        break;
      }
    }
  }
  const deduped = new Map<string, { grade: "diesel_500ppm" | "diesel_50ppm"; pricePerLitre: number; rawValue: number; unit: string; evidence: string }>();
  for (const result of results) deduped.set(result.grade, result);
  return [...deduped.values()];
}

async function zipEntries(bytes: Uint8Array): Promise<Array<{ name: string; bytes: Uint8Array }>> {
  const entries: Array<{ name: string; bytes: Uint8Array }> = [];
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 0;
  while (offset + 30 < bytes.length) {
    if (view.getUint32(offset, true) !== 0x04034b50) {
      offset += 1;
      continue;
    }
    const method = view.getUint16(offset + 8, true);
    const compressedSize = view.getUint32(offset + 18, true);
    const fileNameLength = view.getUint16(offset + 26, true);
    const extraLength = view.getUint16(offset + 28, true);
    const nameStart = offset + 30;
    const dataStart = nameStart + fileNameLength + extraLength;
    const name = new TextDecoder().decode(bytes.slice(nameStart, nameStart + fileNameLength));
    const compressed = bytes.slice(dataStart, dataStart + compressedSize);
    let entryBytes: Uint8Array | null = null;
    if (method === 0) {
      entryBytes = compressed;
    } else if (method === 8) {
      const stream = new Blob([compressed]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
      entryBytes = new Uint8Array(await new Response(stream).arrayBuffer());
    }
    if (entryBytes) entries.push({ name, bytes: entryBytes });
    offset = dataStart + compressedSize;
  }
  return entries;
}

function xmlPlainText(xml: string): string {
  return normalizeWhitespace(decodeHtml(xml.replace(/<[^>]+>/g, " ")));
}

function parseSharedStrings(xml: string): string[] {
  return [...xml.matchAll(/<si\b[\s\S]*?<\/si>/gi)].map((match) =>
    normalizeWhitespace([...match[0].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/gi)].map((part) => decodeHtml(part[1])).join(""))
  );
}

function parseWorksheetRows(xml: string, shared: string[]): string {
  const lines: string[] = [];
  for (const row of xml.matchAll(/<row\b[^>]*>([\s\S]*?)<\/row>/gi)) {
    const values: string[] = [];
    for (const cell of row[1].matchAll(/<c\b([^>]*)>([\s\S]*?)<\/c>/gi)) {
      const attrs = cell[1];
      const body = cell[2];
      const value = body.match(/<v[^>]*>([\s\S]*?)<\/v>/i)?.[1] ?? "";
      if (/\bt=["']s["']/i.test(attrs)) {
        values.push(shared[Number(value)] ?? "");
      } else if (/\bt=["']inlineStr["']/i.test(attrs)) {
        values.push(xmlPlainText(body));
      } else {
        values.push(normalizeWhitespace(value));
      }
    }
    const line = values.filter(Boolean).join(" | ");
    if (line) lines.push(line);
  }
  return lines.join("\n");
}

async function parseSpreadsheetText(bytes: Uint8Array): Promise<string> {
  const entries = await zipEntries(bytes);
  const sharedEntry = entries.find((entry) => /xl\/sharedStrings\.xml$/i.test(entry.name));
  const shared = sharedEntry ? parseSharedStrings(new TextDecoder("utf-8", { fatal: false }).decode(sharedEntry.bytes)) : [];
  const sheets = entries
    .filter((entry) => /xl\/worksheets\/sheet[0-9]+\.xml$/i.test(entry.name))
    .sort((left, right) => left.name.localeCompare(right.name));
  return sheets.map((sheet) => parseWorksheetRows(new TextDecoder("utf-8", { fatal: false }).decode(sheet.bytes), shared)).join("\n");
}

async function parseZipText(bytes: Uint8Array, depth = 0): Promise<string> {
  const parts: string[] = [];
  const entries = await zipEntries(bytes);
  const restrictToFuelSchedule = depth === 0 && entries.some((entry) => /fuel price schedule.*\.xlsx$/i.test(entry.name));
  for (const entry of entries) {
    const name = entry.name;
    if (restrictToFuelSchedule && !/fuel price schedule.*\.xlsx$/i.test(name)) {
      continue;
    }
    if (/\.(xml|txt|csv|html?)$/i.test(name)) {
      parts.push(new TextDecoder("utf-8", { fatal: false }).decode(entry.bytes));
    } else if (/\.xlsx$/i.test(name)) {
      parts.push(await parseSpreadsheetText(entry.bytes));
    } else if (/\.(docx|zip)$/i.test(name) && depth < 3) {
      parts.push(await parseZipText(entry.bytes, depth + 1));
    }
  }
  return parts.join("\n")
    .replace(/<[^>]+>/g, " ")
    .split(/\r?\n/)
    .map((line) => normalizeWhitespace(line))
    .filter(Boolean)
    .join("\n");
}

async function publicationText(response: Response): Promise<{ text: string; contentType: string }> {
  const contentType = response.headers.get("content-type") ?? "";
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (/zip|spreadsheet|octet-stream/i.test(contentType) || (bytes[0] === 0x50 && bytes[1] === 0x4b)) {
    return { text: await parseZipText(bytes), contentType };
  }
  return { text: new TextDecoder("utf-8", { fatal: false }).decode(bytes), contentType };
}

async function refreshOfficialDiesel(req: Request, body: JsonMap) {
  const scheduledSecret = req.headers.get("x-diesel-refresh-secret") ?? String(body.refreshSecret ?? "");
  const isScheduled = Boolean(dieselRefreshSecret) && scheduledSecret === dieselRefreshSecret;
  if (!isScheduled) await requireInternal(req, "manage_rfqs");

  const pageResponse = await fetch(dmprFuelPricesUrl, { headers: { "user-agent": "Time Trucking Auto-Quote diesel refresh" } });
  if (!pageResponse.ok) throw new Error(`DMPR fuel price page returned ${pageResponse.status}.`);
  const pageHtml = await pageResponse.text();
  const publication = latestDmprPublication(pageHtml);
  const sourceUrl = absoluteUrl(publication.href, dmprFuelPricesUrl);
  const documentResponse = await fetch(sourceUrl, { redirect: "follow", headers: { "user-agent": "Time Trucking Auto-Quote diesel refresh" } });
  if (!documentResponse.ok) throw new Error(`DMPR fuel price publication returned ${documentResponse.status}.`);
  const document = await publicationText(documentResponse);
  const effectiveDate = publication.effectiveDate ?? parseEffectiveDate(document.text);
  if (!effectiveDate) throw new Error("DMPR effective date could not be validated.");
  const parsed = parseDieselPricesFromText(document.text);
  const requestedGrade = String(body.dieselGrade ?? "");
  const gradeRecord = parsed.find((entry) => entry.grade === requestedGrade) ?? parsed[0];
  if (!gradeRecord) {
    await serviceClient.rpc("ttaq_record_diesel_provider_result", {
      provider_key_value: "za_dmpr_official_diesel",
      provider_status_value: "failed",
      provider_price_per_litre_value: null,
      effective_from_value: effectiveDate,
      provider_response_value: {
        source_url: sourceUrl,
        source_title: publication.title,
        publication_effective_date: effectiveDate,
        content_type: document.contentType,
        raw_source_metadata: { parsed_grade_count: 0 }
      },
      error_message_value: "No valid diesel grade price could be extracted from the official DMPR publication."
    });
    throw new Error("No valid diesel grade price could be extracted from the official DMPR publication.");
  }

  const { data, error } = await serviceClient.rpc("ttaq_record_diesel_provider_result", {
    provider_key_value: "za_dmpr_official_diesel",
    provider_status_value: "verified",
    provider_price_per_litre_value: gradeRecord.pricePerLitre,
    effective_from_value: effectiveDate,
    provider_response_value: {
      source_url: sourceUrl,
      source_title: publication.title,
      publication_date: effectiveDate,
      diesel_grade: gradeRecord.grade,
      pricing_basis: String(body.pricingBasis ?? "unconfigured"),
      unit: "ZAR/L",
      raw_value: gradeRecord.rawValue,
      raw_unit: gradeRecord.unit,
      conversion: /c/i.test(gradeRecord.unit) ? "cents_per_litre_to_zar_per_litre" : "already_zar_per_litre",
      content_type: document.contentType,
      raw_source_metadata: {
        dmpr_page_url: dmprFuelPricesUrl,
        source_url: sourceUrl,
        source_title: publication.title,
        parsed_grade_count: parsed.length,
        evidence: gradeRecord.evidence
      }
    },
    error_message_value: null
  });
  if (error) throw error;
  return {
    status: "verified",
    dieselIntegrationId: data,
    source: "DMPR official monthly fuel price publication",
    sourceUrl,
    sourceTitle: publication.title,
    effectiveDate,
    dieselGrade: gradeRecord.grade,
    officialReferencePricePerLitre: gradeRecord.pricePerLitre,
    unit: "ZAR/L"
  };
}

async function installDieselScheduler(req: Request, body: JsonMap) {
  const scheduledSecret = req.headers.get("x-diesel-refresh-secret") ?? String(body.refreshSecret ?? "");
  if (!dieselRefreshSecret || scheduledSecret !== dieselRefreshSecret) {
    throw new Error("Diesel scheduler installation requires the server-side refresh secret.");
  }
  const publishableKey = anonKey || Object.values(JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}"))[0];
  if (!publishableKey || typeof publishableKey !== "string") {
    throw new Error("Supabase publishable key is not available to configure scheduler invocation.");
  }
  const { error } = await serviceClient.rpc("ttaq_install_diesel_refresh_schedule", {
    refresh_secret_value: dieselRefreshSecret,
    publishable_key_value: publishableKey
  });
  if (error) throw error;
  return {
    status: "configured",
    scheduler: "Supabase Cron + pg_net + Vault",
    schedule: "17 4 * * *",
    secretStoredInVault: true
  };
}

async function refreshOfficialTolls(req: Request, body: JsonMap) {
  const scheduledSecret = req.headers.get("x-diesel-refresh-secret") ?? String(body.refreshSecret ?? "");
  const isScheduled = Boolean(dieselRefreshSecret) && scheduledSecret === dieselRefreshSecret;
  if (!isScheduled) await requireInternal(req, "manage_rfqs");

  const providers = [
    {
      providerKey: "za_sanral_official_tolls",
      sourceUrl: "https://www.nra.co.za/publications/sanral-announces-toll-tariff-adjustment-effective-1-march-2026",
      titlePattern: /toll tariff adjustment effective 1 march 2026/i,
      effectiveDate: "2026-03-01",
      expectedTitle: "SANRAL toll tariff adjustment effective 1 March 2026",
      mode: "incomplete"
    },
    {
      providerKey: "za_bakwena_official_tolls",
      sourceUrl: "https://www.bakwena.co.za/tolls-and-tariffs/",
      titlePattern: /1\s+March\s+2026|28\s+February\s+2027|Stormvoel|Swartruggens/i,
      effectiveDate: "2026-03-01",
      expectedTitle: "Bakwena toll tariffs applicable from 1 March 2026 to 28 February 2027",
      mode: "verified"
    },
    {
      providerKey: "za_trac_n4_official_tolls",
      sourceUrl: "https://tracn4.co.za/toll-plazas-toll-fees/",
      titlePattern: /toll fees|1\s+March\s+2026|N4/i,
      effectiveDate: "2026-03-01",
      expectedTitle: "TRAC N4 toll fees effective from 1 March 2026",
      mode: "verified"
    },
    {
      providerKey: "za_n3tc_official_tolls",
      sourceUrl: "https://www.n3tc.co.za/toll-tariffs/",
      titlePattern: /toll tariffs|1\s+March\s+2026|N3/i,
      effectiveDate: "2026-03-01",
      expectedTitle: "N3TC toll fee groups effective from 1 March 2026",
      mode: "verified"
    }
  ];

  const results: JsonMap[] = [];
  for (const provider of providers) {
    try {
      const response = await fetch(provider.sourceUrl, { headers: { "user-agent": "Time Trucking Auto-Quote toll tariff refresh" } });
      if (!response.ok) throw new Error(`Official toll source returned ${response.status}.`);
      const sourceText = await response.text();
      const sourceLooksCurrent = provider.titlePattern.test(sourceText);
      if (!sourceLooksCurrent) throw new Error("Official toll source did not match the expected 2026 publication markers.");
      const { count, error } = await serviceClient
        .from("toll_tariffs")
        .select("id", { count: "exact", head: true })
        .eq("source_provider", provider.providerKey)
        .eq("effective_from", provider.effectiveDate);
      if (error) throw error;
      const status = provider.mode === "verified" ? "complete" : "partial";
      const { data: runId, error: recordError } = await serviceClient.rpc("ttaq_record_toll_import_result", {
        provider_key_value: provider.providerKey,
        provider_status_value: status,
        publication_effective_date_value: provider.effectiveDate,
        publication_title_value: provider.expectedTitle,
        source_url_value: provider.sourceUrl,
        imported_plaza_count_value: count ?? 0,
        provider_response_value: {
          source_url: provider.sourceUrl,
          publication_effective_date: provider.effectiveDate,
          current_publication_detected: true,
          import_mode: provider.mode,
          coverage_status: status,
          note: provider.mode === "verified"
            ? "Existing official Bakwena tariff rows remain current; duplicate import skipped."
            : "Provider source is current, but automatic charging remains incomplete until official plaza coordinate/rate rows are loaded."
        },
        error_message_value: provider.mode === "verified" ? null : "Official source detected but tariff coverage is incomplete."
      });
      if (recordError) throw recordError;
      results.push({ providerKey: provider.providerKey, status, runId, importedPlazaCount: count ?? 0 });
    } catch (error) {
      await serviceClient.rpc("ttaq_record_toll_import_result", {
        provider_key_value: provider.providerKey,
        provider_status_value: "failed",
        publication_effective_date_value: provider.effectiveDate,
        publication_title_value: provider.expectedTitle,
        source_url_value: provider.sourceUrl,
        imported_plaza_count_value: 0,
        provider_response_value: { source_url: provider.sourceUrl },
        error_message_value: errorMessage(error, "Official toll source check failed.")
      });
      results.push({ providerKey: provider.providerKey, status: "failed", error: errorMessage(error) });
    }
  }
  return {
    status: results.some((result) => result.status === "failed") ? "needs_attention" : "checked",
    source: "Official toll operator/source publications",
    schedule: "Weekly source check through Supabase Cron, pg_net, and Vault secret invocation",
    results
  };
}

async function installTollScheduler(req: Request, body: JsonMap) {
  const scheduledSecret = req.headers.get("x-diesel-refresh-secret") ?? String(body.refreshSecret ?? "");
  if (!dieselRefreshSecret || scheduledSecret !== dieselRefreshSecret) {
    throw new Error("Toll scheduler installation requires the server-side refresh secret.");
  }
  const { error } = await serviceClient.rpc("ttaq_install_toll_refresh_schedule");
  if (error) throw error;
  return {
    status: "configured",
    scheduler: "Supabase Cron + pg_net + Vault",
    schedule: "23 5 * * 1",
    secretStoredInVault: true
  };
}

function requireDieselRefreshSecret(req: Request, body: JsonMap): void {
  const scheduledSecret = req.headers.get("x-diesel-refresh-secret") ?? String(body.refreshSecret ?? "");
  if (!dieselRefreshSecret || scheduledSecret !== dieselRefreshSecret) {
    throw new Error("Diesel scheduler status requires the server-side refresh secret.");
  }
}

async function triggerDieselSchedulerOnce(req: Request, body: JsonMap) {
  requireDieselRefreshSecret(req, body);
  const { data, error } = await serviceClient.rpc("ttaq_trigger_official_diesel_refresh", {
    trigger_source_value: "manual_scheduler_test"
  });
  if (error) throw error;
  return { status: "queued", requestId: data };
}

async function dieselSchedulerStatus(req: Request, body: JsonMap) {
  requireDieselRefreshSecret(req, body);
  const [
    providerResult,
    runsResult,
    officialResult,
    schedulerResult,
    activeProfileResult
  ] = await Promise.all([
    serviceClient.from("pricing_external_providers").select("provider_key,provider_status,scheduler_status,last_check_at,next_expected_check_at,last_success_at,last_failure_at,last_error,last_publication_effective_date,last_publication_title").eq("provider_key", "za_dmpr_official_diesel").maybeSingle(),
    serviceClient.from("pricing_provider_refresh_runs").select("provider_key,trigger_source,request_id,status,requested_at").eq("provider_key", "za_dmpr_official_diesel").order("requested_at", { ascending: false }).limit(5),
    serviceClient.from("diesel_price_integrations").select("id,diesel_grade,official_reference_price_per_litre,effective_diesel_price_per_litre,effective_from,provider_status,validation_status,source_document_title,created_at").eq("provider_name", "za_dmpr_official_diesel").order("created_at", { ascending: false }).limit(8),
    serviceClient.rpc("ttaq_diesel_scheduler_status"),
    serviceClient.rpc("ttaq_active_pricing_profile")
  ]);
  for (const result of [providerResult, runsResult, officialResult, schedulerResult, activeProfileResult]) {
    if (result.error) throw result.error;
  }
  let currentDiesel: unknown = null;
  const activeProfile = activeProfileResult.data;
  if (typeof activeProfile === "string") {
    const { data, error } = await serviceClient.rpc("ttaq_current_diesel_input", { profile_id: activeProfile });
    if (error) throw error;
    currentDiesel = data;
  }
  return {
    provider: providerResult.data,
    recentRuns: runsResult.data,
    officialRecords: officialResult.data,
    scheduler: schedulerResult.data,
    currentDiesel
  };
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
    const encodedPolyline = (route.polyline as JsonMap | undefined)?.encodedPolyline ? String((route.polyline as JsonMap).encodedPolyline) : null;
    const tollPlazaMatching = await matchOfficialTollPlazas(encodedPolyline);
    const routePathPoints = sampledRoutePoints(encodedPolyline);
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
      overview_polyline: encodedPolyline,
      route_path_points: routePathPoints,
      route_geometry_status: routePathPoints.length ? "available" : "unavailable",
      toll_status: tollStatus(route),
      toll_info: (route.travelAdvisory as JsonMap | undefined)?.tollInfo ?? null,
      toll_plaza_matching: tollPlazaMatching,
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

    if (action === "invite_internal_user") {
      return json(req, 200, await inviteInternalUser(req, body));
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

    if (action === "diesel_scheduler_status") {
      return json(req, 200, await dieselSchedulerStatus(req, body));
    }

    if (action === "install_diesel_scheduler") {
      return json(req, 200, await installDieselScheduler(req, body));
    }

    if (action === "install_toll_scheduler") {
      return json(req, 200, await installTollScheduler(req, body));
    }

    if (action === "refresh_official_diesel") {
      return json(req, 200, await refreshOfficialDiesel(req, body));
    }

    if (action === "refresh_official_tolls") {
      return json(req, 200, await refreshOfficialTolls(req, body));
    }

    if (action === "trigger_diesel_scheduler_once") {
      return json(req, 200, await triggerDieselSchedulerOnce(req, body));
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
