import { createClient } from "@supabase/supabase-js";
import type { CargoCategory, CustomerPortalRecord, InternalRole, InternalSettingsPayload, InternalUserRecord, PublicQuoteDocumentRecord, PublicQuoteResponseRecord, QuoteDocumentRecord, QuoteRequestRecord, QuoteStatus, StopType } from "./types";

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const isSupabaseConfigured = Boolean(supabaseUrl && supabaseAnonKey);

export const supabase = isSupabaseConfigured
  ? createClient(supabaseUrl as string, supabaseAnonKey as string)
  : null;

async function invokeProductionIntegration<T>(action: string, payload: Record<string, unknown> = {}): Promise<T> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.functions.invoke("production-integrations", {
    body: { action, ...payload }
  });
  if (error) throw error;
  return data as T;
}

export async function signInInternalUser(email: string, password: string): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
}

export async function signOutInternalUser(): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.auth.signOut();
  if (error) throw error;
}

export async function hasSupabaseSession(): Promise<boolean> {
  if (!supabase) return false;
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  return Boolean(data.session);
}

export async function loadCurrentInternalUser(): Promise<InternalUserRecord | null> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc("ttaq_get_current_internal_user");
  if (error) throw error;
  const result = Array.isArray(data) ? data[0] : data;
  return (result ?? null) as InternalUserRecord | null;
}

export async function listInternalUsers(): Promise<InternalUserRecord[]> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase
    .from("internal_users")
    .select("id,email,full_name,role,user_status,can_view_all_quotes,can_manage_rfqs,can_approve_quotes,can_adjust_pricing,can_manage_pricing_rules,can_manage_users,invited_by,revoked_at,created_at,last_login_at")
    .order("created_at", { ascending: false });
  if (error) throw error;
  return (data ?? []) as InternalUserRecord[];
}

export async function saveInternalUser(input: {
  id: string;
  email: string;
  fullName: string;
  role: InternalRole;
  canViewAllQuotes: boolean;
  canManageRfqs: boolean;
  canApproveQuotes: boolean;
  canAdjustPricing: boolean;
  canManagePricingRules: boolean;
  canManageUsers: boolean;
}): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.from("internal_users").upsert({
    id: input.id,
    email: input.email,
    full_name: input.fullName || null,
    role: input.role,
    user_status: "active",
    can_view_all_quotes: input.canViewAllQuotes,
    can_manage_rfqs: input.canManageRfqs,
    can_approve_quotes: input.canApproveQuotes,
    can_adjust_pricing: input.canAdjustPricing,
    can_manage_pricing_rules: input.canManagePricingRules,
    can_manage_users: input.canManageUsers,
    revoked_at: null
  });
  if (error) throw error;
}

export async function revokeInternalUser(userId: string): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_revoke_internal_user", {
    target_user_id: userId
  });
  if (error) throw error;
}

export async function reactivateInternalUser(userId: string): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase
    .from("internal_users")
    .update({ user_status: "active", revoked_at: null })
    .eq("id", userId);
  if (error) throw error;
}

export interface PublicRfqPayload {
  company_name: string;
  contact_person: string;
  email: string;
  phone: string;
  collection_address: string;
  delivery_address: string;
  cargo_type: string;
  load_description: string;
  quantity: number;
  length_m: number;
  width_m: number;
  height_m: number;
  weight_kg: number;
  stackable: boolean;
  load_type: "dedicated" | "part_load";
  loading_method: string;
  offloading_method: string;
  goods_value: number;
  insurance_required: boolean;
  collection_date: string;
  delivery_date: string;
  special_requirements: string;
  attachment_note: string;
  suggestion_notes: string;
  is_final: boolean;
  stops: PublicRfqStopPayload[];
  cargo_items: PublicRfqCargoItemPayload[];
  dynamic_answers: PublicRfqDynamicAnswerPayload[];
}

export interface PublicRfqStopPayload {
  stop_order: number;
  sequence_number?: number;
  stop_type: StopType;
  address: string;
  latitude?: number | null;
  longitude?: number | null;
  place_id?: string | null;
  formatted_address?: string | null;
  contact_name: string;
  contact_phone: string;
  date_time_window: string;
  loading_method: string;
  offloading_method: string;
  notes: string;
}

export interface PublicRfqCargoItemPayload {
  client_item_key: string;
  description: string;
  cargo_category: CargoCategory;
  quantity: number;
  length_m: number;
  width_m: number;
  height_m: number;
  weight_kg: number;
  stackable: boolean;
  fragile: boolean;
  dangerous_goods: boolean;
  temperature_controlled: boolean;
  cargo_value: number;
  notes: string;
}

export interface PublicRfqDynamicAnswerPayload {
  client_item_key: string;
  answer_group: string;
  question_key: string;
  answer_value: string;
}

export interface PublicRfqResult {
  quote_request_id: string;
  public_reference: string;
  response_token: string;
}

export async function submitPublicRfq(rawToken: string | null, payload: PublicRfqPayload): Promise<PublicRfqResult> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const responseToken = crypto.randomUUID().replaceAll("-", "");
  const { data, error } = await supabase.rpc("ttaq_submit_public_rfq", {
    raw_rfq_token: rawToken,
    raw_response_token: responseToken,
    payload,
    is_final: payload.is_final
  });
  if (error) throw error;
  const result = Array.isArray(data) ? data[0] : data;
  return result as PublicRfqResult;
}

export async function autoRouteSubmittedRfq(input: {
  quoteRequestId: string;
  responseToken: string;
  publicReference: string;
}): Promise<{ status: string; distanceKm?: number; durationHours?: number; error?: string | null }> {
  return invokeProductionIntegration("auto_route_public_rfq", {
    quoteRequestId: input.quoteRequestId,
    responseToken: input.responseToken,
    publicReference: input.publicReference
  });
}

export async function loadAdminQuoteRequests(): Promise<QuoteRequestRecord[]> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase
    .from("quote_requests")
    .select("*, quote_items(*), quote_stops(*), rfq_dynamic_answers(*), vehicle_recommendations(*), transport_requirement_flags(*), route_estimates(*, route_estimate_stops(*)), pricing_calculations(*, pricing_breakdowns(*), pricing_calculation_audit_events(*)), pricing_adjustments(*), pricing_component_overrides(*), quote_documents(*), transport_jobs(*)")
    .order("created_at", { ascending: false });
  if (error) throw error;
  return (data ?? []) as QuoteRequestRecord[];
}

export async function loadAdminQuoteRequest(id: string): Promise<QuoteRequestRecord | null> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase
    .from("quote_requests")
    .select("*, quote_items(*), quote_stops(*), rfq_dynamic_answers(*), vehicle_recommendations(*), transport_requirement_flags(*), route_estimates(*, route_estimate_stops(*)), pricing_calculations(*, pricing_breakdowns(*), pricing_calculation_audit_events(*)), pricing_adjustments(*), pricing_component_overrides(*), quote_documents(*), transport_jobs(*)")
    .eq("id", id)
    .maybeSingle();
  if (error) throw error;
  return data as QuoteRequestRecord | null;
}

export async function updateAdminQuote(
  id: string,
  values: { adminNotes: string; adjustedPrice: number; status: Extract<QuoteStatus, "approved" | "sent_to_client"> }
): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_update_internal_quote_review", {
    target_quote_request_id: id,
    admin_notes_value: values.adminNotes,
    adjusted_price_value: values.adjustedPrice,
    next_status: values.status
  });
  if (error) throw error;
}

export async function archiveQuoteRequest(id: string, note: string): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_archive_quote_request", {
    target_quote_request_id: id,
    archive_note: note || null
  });
  if (error) throw error;
}

export async function createInternalRfqLink(input: {
  companyName: string;
  email: string;
  referenceNumber: string;
  expiresOn: string;
  rawToken: string;
}): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_create_internal_rfq_link", {
    raw_rfq_token: input.rawToken,
    company_name_value: input.companyName,
    email_value: input.email,
    public_reference_value: input.referenceNumber || null,
    expires_on_value: input.expiresOn || null
  });
  if (error) throw error;
}

export async function loadPublicQuoteResponse(rawToken: string | null, reference: string | null): Promise<PublicQuoteResponseRecord | null> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc("ttaq_get_public_quote_response", {
    raw_response_token: rawToken,
    public_reference_value: reference
  });
  if (error) throw error;
  const result = Array.isArray(data) ? data[0] : data;
  return (result ?? null) as PublicQuoteResponseRecord | null;
}

export async function submitPublicQuoteDecision(
  rawToken: string | null,
  reference: string | null,
  decision: Extract<QuoteStatus, "client_accepted" | "client_declined">
): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_record_public_quote_response", {
    raw_response_token: rawToken,
    public_reference_value: reference,
    decision_status: decision
  });
  if (error) throw error;
}

export async function recordPricingAdjustment(input: {
  quoteRequestId: string;
  pricingCalculationId: string;
  adjustedSellingPrice: number;
  adjustmentReason: string;
}): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_record_pricing_adjustment", {
    target_quote_request_id: input.quoteRequestId,
    target_pricing_calculation_id: input.pricingCalculationId,
    adjusted_selling_price_value: input.adjustedSellingPrice,
    adjustment_reason_value: input.adjustmentReason
  });
  if (error) throw error;
}

export async function recordPricingComponentOverride(input: {
  quoteRequestId: string;
  pricingCalculationId: string;
  lineKey: string;
  overrideAmount: number;
  overrideReason: string;
}): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_record_pricing_component_override", {
    target_quote_request_id: input.quoteRequestId,
    target_pricing_calculation_id: input.pricingCalculationId,
    line_key_value: input.lineKey,
    override_amount_value: input.overrideAmount,
    override_reason_value: input.overrideReason
  });
  if (error) throw error;
}

export async function savePricingSettings(payload: Record<string, unknown>): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_save_pricing_settings", {
    settings_payload: payload
  });
  if (error) throw error;
  const { error: dieselError } = await supabase.rpc("ttaq_save_diesel_integration_settings", {
    settings_payload: payload
  });
  if (dieselError) throw dieselError;
}

export async function updateRouteEstimateManual(input: {
  quoteRequestId: string;
  distanceKm: number;
  durationHours: number;
  reason: string;
}): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_update_route_estimate_manual", {
    target_quote_request_id: input.quoteRequestId,
    manual_distance_km_value: input.distanceKm,
    manual_duration_hours_value: input.durationHours,
    manual_override_reason_value: input.reason
  });
  if (error) throw error;
}

export async function updateRouteEstimateGoogle(input: {
  quoteRequestId: string;
  distanceKm: number;
  durationHours: number;
  googleMapsUrl: string;
  providerResponse: Record<string, unknown>;
  providerStatus: string;
  providerError?: string | null;
}): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_update_route_estimate_google", {
    target_quote_request_id: input.quoteRequestId,
    google_distance_km_value: input.distanceKm,
    google_duration_hours_value: input.durationHours,
    google_maps_url_value: input.googleMapsUrl || null,
    provider_response_value: input.providerResponse,
    provider_status_value: input.providerStatus,
    provider_error_value: input.providerError ?? null
  });
  if (error) throw error;
}

export async function generateQuoteDocument(quoteRequestId: string): Promise<string> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc("ttaq_generate_quote_document", {
    quote_request_id: quoteRequestId
  });
  if (error) throw error;
  return String(data);
}

export async function loadInternalQuoteDocument(input: { quoteDocumentId?: string; quoteRequestId?: string }): Promise<QuoteDocumentRecord | null> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc("ttaq_get_internal_quote_document", {
    target_quote_document_id: input.quoteDocumentId ?? null,
    target_quote_request_id: input.quoteRequestId ?? null
  });
  if (error) throw error;
  const result = Array.isArray(data) ? data[0] : data;
  if (!result) return null;
  return {
    id: result.quote_document_id,
    quote_request_id: result.quote_request_id,
    quote_number: result.quote_number,
    public_reference: result.public_reference,
    quote_date: result.quote_date,
    validity_date: result.validity_date,
    version_number: result.version_number,
    status: result.document_status,
    final_selling_price: result.final_selling_price,
    vat_amount: result.vat_amount,
    currency: result.currency,
    accept_link: null,
    decline_link: null,
    pdf_placeholder_url: null,
    pdf_url: result.pdf_url,
    pdf_storage_path: result.pdf_storage_path,
    generated_at: result.generated_at,
    sent_at: result.sent_at,
    email_sent_to: result.email_sent_to,
    email_status: result.email_status,
    email_error: result.email_error,
    customer_payload: result.customer_payload,
    document_payload: result.document_payload
  } as QuoteDocumentRecord;
}

export async function markQuoteDocumentGenerated(input: {
  quoteDocumentId: string;
  pdfStoragePath?: string | null;
  pdfUrl?: string | null;
}): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_mark_quote_document_generated", {
    target_quote_document_id: input.quoteDocumentId,
    pdf_storage_path_value: input.pdfStoragePath ?? null,
    pdf_url_value: input.pdfUrl ?? null
  });
  if (error) throw error;
}

export async function markQuoteDocumentSent(input: {
  quoteDocumentId: string;
  emailSentTo: string;
  emailStatus: "pending" | "simulated" | "failed" | "sent";
  emailError?: string | null;
}): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_mark_quote_document_sent", {
    target_quote_document_id: input.quoteDocumentId,
    email_sent_to_value: input.emailSentTo,
    email_status_value: input.emailStatus,
    email_error_value: input.emailError ?? null
  });
  if (error) throw error;
}

export async function uploadQuoteDocumentHtml(input: {
  quoteDocumentId: string;
  fileName: string;
  html: string;
}): Promise<{ path: string }> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const path = `${input.quoteDocumentId}/${input.fileName}`;
  const { error } = await supabase.storage
    .from("quote-documents")
    .upload(path, new Blob([input.html], { type: "text/html" }), {
      contentType: "text/html",
      upsert: true
    });
  if (error) throw error;
  return { path };
}

export async function generateQuotePdf(quoteRequestId: string): Promise<{ quoteDocumentId: string; storagePath: string; signedUrl: string; expiresIn: number }> {
  return invokeProductionIntegration("generate_quote_pdf", { quoteRequestId });
}

export async function sendQuoteEmail(input: {
  quoteDocumentId: string;
  to?: string;
}): Promise<{ status: "sent" | "failed"; provider: string; providerMessageId?: string | null; error?: string | null }> {
  return invokeProductionIntegration("send_quote_email", {
    quoteDocumentId: input.quoteDocumentId,
    to: input.to || undefined
  });
}

export async function getPublicQuotePdfUrl(rawToken: string | null, reference: string | null): Promise<{ signedUrl: string; expiresIn: number }> {
  return invokeProductionIntegration("get_quote_pdf_url", {
    token: rawToken,
    reference
  });
}

export async function getInternalDocumentUrl(bucket: "quote-documents", path: string): Promise<{ signedUrl: string; expiresIn: number }> {
  return invokeProductionIntegration("get_internal_document_url", { bucket, path });
}

export async function loadPublicQuoteDocument(rawToken: string | null, reference: string | null): Promise<PublicQuoteDocumentRecord | null> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc("ttaq_get_public_quote_document", {
    raw_response_token: rawToken,
    public_reference_value: reference
  });
  if (error) throw error;
  const result = Array.isArray(data) ? data[0] : data;
  return (result ?? null) as PublicQuoteDocumentRecord | null;
}

export async function requestQuoteRevision(rawToken: string | null, reference: string | null, message: string): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_request_quote_revision", {
    raw_response_token: rawToken,
    public_reference_value: reference,
    revision_message_value: message
  });
  if (error) throw error;
}

export async function loadCustomerPortal(rawToken: string | null, reference: string | null): Promise<CustomerPortalRecord | null> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc("ttaq_get_customer_portal", {
    raw_response_token: rawToken,
    public_reference_value: reference
  });
  if (error) throw error;
  const result = Array.isArray(data) ? data[0] : data;
  return (result ?? null) as CustomerPortalRecord | null;
}

export async function loadInternalSettings(): Promise<InternalSettingsPayload | null> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc("ttaq_get_internal_settings");
  if (error) throw error;
  const result = Array.isArray(data) ? data[0] : data;
  return (result?.settings_payload ?? null) as InternalSettingsPayload | null;
}

export async function updateInternalSettings(payload: InternalSettingsPayload): Promise<InternalSettingsPayload> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc("ttaq_update_internal_settings", {
    settings_payload: payload
  });
  if (error) throw error;
  return data as InternalSettingsPayload;
}
