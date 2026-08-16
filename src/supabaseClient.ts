import { createClient } from "@supabase/supabase-js";
import type { CargoCategory, CommercialRateCardRecord, CustomerPortalRecord, EquipmentSource, InternalRole, InternalSettingsPayload, InternalUserRecord, OperationalJourneySummaryRecord, PublicQuoteDocumentRecord, PublicQuoteResponseRecord, QuoteDocumentRecord, QuoteRequestRecord, QuoteStatus, StandardEquipmentProfileRecord, StopType, VehicleClassInternalCostProfileRecord } from "./types";

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

export async function getCurrentAuthSession(): Promise<boolean> {
  if (!supabase) return false;
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  return Boolean(data.session);
}

export async function updateCurrentUserPassword(password: string): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.auth.updateUser({ password });
  if (error) throw error;
}

export async function requestPasswordReset(email: string): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const redirectTo = `${window.location.origin}${window.location.pathname.replace(/[^/]*$/, "password.html")}`;
  const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo });
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

export async function inviteInternalUser(input: {
  email: string;
  fullName: string;
  phone?: string;
  role: InternalRole;
  permissions?: Record<string, boolean>;
}): Promise<{ status: string; email: string; role: string; message?: string }> {
  return invokeProductionIntegration("invite_internal_user", {
    email: input.email,
    fullName: input.fullName,
    phone: input.phone || undefined,
    role: input.role,
    permissions: input.permissions ?? {}
  });
}

export async function resendInternalInvitationLink(input: { email: string }): Promise<{ status: string; email: string; message?: string }> {
  return invokeProductionIntegration("resend_internal_invitation", {
    email: input.email
  });
}

export async function revokeInternalUser(userId: string): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_revoke_internal_user", {
    target_user_id: userId
  });
  if (error) throw error;
}

export async function saveDefaultOperatingDepot(input: {
  displayName: string;
  fullAddress: string;
  googlePlaceId?: string;
  latitude?: number | null;
  longitude?: number | null;
}): Promise<string | null> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc("ttaq_save_default_operating_depot", {
    depot_payload: {
      display_name: input.displayName,
      full_address: input.fullAddress,
      google_place_id: input.googlePlaceId || null,
      latitude: input.latitude ?? null,
      longitude: input.longitude ?? null
    }
  });
  if (error) throw error;
  return (data ?? null) as string | null;
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

export async function loadOperationalJourneySummary(quoteRequestId: string): Promise<OperationalJourneySummaryRecord | null> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc("ttaq_quote_operational_journey_summary", {
    target_quote_request_id: quoteRequestId
  });
  if (error) throw error;
  return (data ?? null) as OperationalJourneySummaryRecord | null;
}

export async function updateQuoteReturnLoadStatus(input: {
  quoteRequestId: string;
  returnLoadStatus: string;
  notes?: string;
}): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_update_quote_return_load_status", {
    target_quote_request_id: input.quoteRequestId,
    return_load_status_value: input.returnLoadStatus,
    notes_value: input.notes ?? null
  });
  if (error) throw error;
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

export async function recordRouteRiskOverride(input: {
  quoteRequestId: string;
  pricingCalculationId: string;
  overrideRiskCategory: string;
  overrideRiskAmount: number;
  overrideReason: string;
}): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_record_route_risk_override", {
    target_quote_request_id: input.quoteRequestId,
    target_pricing_calculation_id: input.pricingCalculationId,
    override_risk_category_value: input.overrideRiskCategory,
    override_risk_amount_value: input.overrideRiskAmount,
    override_reason_value: input.overrideReason
  });
  if (error) throw error;
}

export async function listStandardEquipmentProfiles(): Promise<StandardEquipmentProfileRecord[]> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase
    .from("standard_equipment_profiles")
    .select("*")
    .eq("is_active", true)
    .order("recommendation_priority", { ascending: true });
  if (error) throw error;
  return (data ?? []) as StandardEquipmentProfileRecord[];
}

export async function applyEquipmentOverride(input: {
  quoteRequestId: string;
  equipmentProfileId: string | null;
  unitCount: number;
  equipmentSource: EquipmentSource;
  overrideReason: string;
}): Promise<string> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc("ttaq_apply_equipment_override", {
    target_quote_request_id: input.quoteRequestId,
    target_equipment_profile_id: input.equipmentProfileId,
    unit_count_value: input.unitCount,
    equipment_source_value: input.equipmentSource,
    override_reason_value: input.overrideReason
  });
  if (error) throw error;
  return String(data);
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

export async function saveCommercialRateCard(rows: CommercialRateCardRecord[]): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  for (const row of rows) {
    const { error } = await supabase
      .from("time_trucking_commercial_rate_card")
      .update({
        day_rate: row.day_rate,
        per_km_rate: row.per_km_rate,
        axle_count_default: row.axle_count_default,
        is_active: row.is_active
      })
      .eq("id", row.id);
    if (error) throw error;
  }
}

export async function saveCommercialPricingSettings(payload: Record<string, unknown>): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_save_commercial_pricing_settings", {
    settings_payload: payload
  });
  if (error) throw error;
}

export async function saveVehicleClassInternalCostProfile(profile: VehicleClassInternalCostProfileRecord): Promise<void> {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.rpc("ttaq_save_vehicle_class_internal_cost_profile", {
    profile_payload: {
      vehicle_class_key: profile.vehicle_class_key,
      display_name: profile.display_name,
      effective_from: profile.effective_from,
      source_basis: profile.source_basis,
      notes: profile.notes,
      profile_status: profile.profile_status,
      components: profile.components
    }
  });
  if (error) throw error;
}

export async function refreshOfficialDieselPrice(): Promise<Record<string, unknown>> {
  return invokeProductionIntegration<Record<string, unknown>>("refresh_official_diesel");
}

export async function loadPricingSettings(): Promise<Record<string, unknown>> {
  if (!supabase) throw new Error("Supabase is not configured.");

  const { data: profile, error: profileError } = await supabase
    .from("pricing_profiles")
    .select("*")
    .eq("is_active", true)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (profileError) throw profileError;
  if (!profile) throw new Error("No active pricing profile is configured.");

  const profileId = String(profile.id);
  const [
    dieselResult,
    dieselConfigResult,
    settingsResult,
    vehicleResult,
    driverResult,
    overheadResult,
    marginResult,
    providerResult,
    tollProvidersResult,
    tollCatalogueResult,
    routeRiskPolicyResult,
    commercialRateCardResult,
    vehicleClassInternalCostProfilesResult,
    equipmentProfilesResult
  ] = await Promise.all([
    supabase.rpc("ttaq_current_diesel_input", { profile_id: profileId }),
    supabase.from("pricing_diesel_configuration").select("*").eq("pricing_profile_id", profileId).maybeSingle(),
    supabase.from("pricing_settings").select("setting_key,setting_value").eq("pricing_profile_id", profileId),
    supabase.from("vehicle_operating_costs").select("*").eq("pricing_profile_id", profileId).order("updated_at", { ascending: false }).limit(1).maybeSingle(),
    supabase.from("driver_costs").select("*").eq("pricing_profile_id", profileId).order("created_at", { ascending: false }).limit(1).maybeSingle(),
    supabase.from("company_overheads").select("*").eq("pricing_profile_id", profileId).order("created_at", { ascending: false }).limit(1).maybeSingle(),
    supabase.from("company_margin_profiles").select("*").eq("pricing_profile_id", profileId).eq("is_default", true).eq("is_active", true).order("created_at", { ascending: false }).limit(1).maybeSingle(),
    supabase.from("pricing_external_providers").select("provider_status,last_success_at,last_failure_at,last_error,last_check_at,next_expected_check_at,last_publication_effective_date,last_publication_title,scheduler_status").eq("provider_key", "za_dmpr_official_diesel").maybeSingle(),
    supabase.rpc("ttaq_toll_provider_status"),
    supabase.rpc("ttaq_current_toll_catalogue"),
    supabase.rpc("ttaq_route_risk_policy_summary"),
    supabase.from("time_trucking_commercial_rate_card").select("*").eq("pricing_profile_id", profileId).order("rate_category_key", { ascending: true }).order("hazardous", { ascending: true }),
    supabase.rpc("ttaq_vehicle_class_internal_cost_profile_summary"),
    supabase.from("standard_equipment_profiles").select("*").eq("is_active", true).order("recommendation_priority", { ascending: true })
  ]);

  for (const result of [dieselResult, dieselConfigResult, settingsResult, vehicleResult, driverResult, overheadResult, marginResult, providerResult, tollProvidersResult, tollCatalogueResult, routeRiskPolicyResult, commercialRateCardResult, vehicleClassInternalCostProfilesResult, equipmentProfilesResult]) {
    if (result.error) throw result.error;
  }

  const settings = Object.fromEntries(
    ((settingsResult.data ?? []) as Array<{ setting_key: string; setting_value: number }>).map((row) => [row.setting_key, row.setting_value])
  );
  const diesel = Array.isArray(dieselResult.data) ? dieselResult.data[0] : dieselResult.data;
  const dieselConfig = dieselConfigResult.data ?? {};
  const dieselSource = (diesel?.source_payload ?? {}) as Record<string, unknown>;
  const vehicle = vehicleResult.data ?? {};
  const driver = driverResult.data ?? {};
  const overhead = overheadResult.data ?? {};
  const margin = marginResult.data ?? {};
  const provider = (providerResult.data ?? {}) as Record<string, unknown>;
  const tollProviders = (tollProvidersResult.data ?? []) as Array<Record<string, unknown>>;
  const tollCatalogue = (tollCatalogueResult.data ?? []) as Array<Record<string, unknown>>;
  const routeRiskPolicy = (routeRiskPolicyResult.data ?? {}) as Record<string, unknown>;
  const commercialRateCard = (commercialRateCardResult.data ?? []) as CommercialRateCardRecord[];
  const vehicleClassInternalCostProfiles = (vehicleClassInternalCostProfilesResult.data ?? []) as VehicleClassInternalCostProfileRecord[];
  const equipmentProfiles = (equipmentProfilesResult.data ?? []) as StandardEquipmentProfileRecord[];
  const tollProviderHealthy = tollProviders.some((row) => row.coverage_status === "complete")
    && !tollProviders.some((row) => row.coverage_status === "unavailable" || row.coverage_status === "needs_review" || row.scheduler_status === "needs_attention");
  const dieselCurrent = Number(dieselSource.effective_diesel_price_per_litre ?? diesel?.price_per_litre ?? 0);
  const dieselBaseline = Number(settings.diesel_base_price_per_litre ?? 0);
  const dieselVariance = dieselCurrent - dieselBaseline;

  return {
    profile_id: profileId,
    profile_name: profile.name,
    currency: profile.currency,
    quote_validity_days: profile.quote_validity_days,
    rule_version: profile.rule_version,
    fuel_price_per_litre: diesel?.price_per_litre,
    diesel_previous_price_per_litre: diesel?.previous_price_per_litre,
    diesel_base_price_per_litre: settings.diesel_base_price_per_litre,
    diesel_variance_amount_per_litre: Number.isFinite(dieselVariance) ? dieselVariance.toFixed(4) : "",
    diesel_variance_percent: dieselBaseline > 0 ? ((dieselVariance / dieselBaseline) * 100).toFixed(4) : "",
    diesel_selling_adjustment_status: "Pending approved Time Trucking formula",
    diesel_effective_from: diesel?.effective_from,
    diesel_provider_id: diesel?.provider_name,
    diesel_provider_status: diesel?.provider_status,
    diesel_source_label: diesel?.source_label,
    diesel_refreshed_at: diesel?.retrieved_at,
    diesel_official_reference_price_per_litre: dieselSource.official_reference_price_per_litre,
    diesel_effective_price_per_litre: dieselSource.effective_diesel_price_per_litre ?? diesel?.price_per_litre,
    preferred_diesel_grade: dieselConfig.preferred_diesel_grade ?? dieselSource.preferred_diesel_grade,
    diesel_pricing_basis: dieselConfig.pricing_basis ?? dieselSource.configured_pricing_basis,
    diesel_pricing_zone: dieselConfig.pricing_zone ?? dieselSource.configured_pricing_zone,
    diesel_depot_location: dieselConfig.depot_location ?? dieselSource.configured_depot_location,
    diesel_adjustment_type: dieselConfig.adjustment_type ?? dieselSource.configured_adjustment_type,
    diesel_adjustment_value: dieselConfig.adjustment_value ?? dieselSource.configured_adjustment_value,
    diesel_adjustment_reason: dieselConfig.adjustment_reason,
    diesel_override_reason: dieselConfig.manual_override_reason ?? dieselSource.manual_override_reason,
    diesel_override_starts_at: dieselConfig.manual_override_starts_at ?? dieselSource.override_started_at,
    diesel_override_expires_at: dieselConfig.manual_override_expires_at ?? dieselSource.override_expires_at,
    diesel_status_detail: dieselSource.review_warning ?? diesel?.source_label,
    diesel_source_url: dieselSource.source_url,
    diesel_source_title: dieselSource.source_title,
    diesel_feed_health: ["configured", "queued"].includes(String(provider.scheduler_status ?? "")) && provider.provider_status === "configured" && !provider.last_error
      ? "Official diesel feed healthy"
      : "Official diesel feed needs attention",
    diesel_last_scheduled_check: provider.last_check_at,
    diesel_next_expected_check: provider.next_expected_check_at,
    diesel_last_provider_success: provider.last_success_at,
    diesel_last_provider_failure: provider.last_failure_at,
    diesel_last_provider_error: provider.last_error,
    diesel_scheduler_status: provider.scheduler_status,
    toll_feed_health: tollProviderHealthy ? "Official toll feed healthy" : "Official toll feed needs attention",
    toll_provider_status_rows: tollProviders,
    toll_catalogue_rows: tollCatalogue,
    commercial_rate_card_rows: commercialRateCard,
    vehicle_class_internal_cost_profiles: vehicleClassInternalCostProfiles,
    standard_equipment_profiles: equipmentProfiles,
    route_risk_categories: Array.isArray(routeRiskPolicy.categories) ? routeRiskPolicy.categories : [],
    route_risk_rules: Array.isArray(routeRiskPolicy.rules) ? routeRiskPolicy.rules : [],
    route_risk_policy_status: Array.isArray(routeRiskPolicy.rules) && routeRiskPolicy.rules.length
      ? "Time Trucking route-risk policy configured"
      : "No Time Trucking risk rule configured/matched",
    toll_active_plaza_count: tollCatalogue.length,
    toll_active_tariff_effective_date: tollCatalogue[0]?.effective_from,
    toll_vat_treatment: "Official toll tariff rows are VAT-inclusive cost inputs; customer quote VAT remains calculated on the final selling price.",
    diesel_admin_override_price_per_litre: diesel?.manual_override ? diesel?.price_per_litre : null,
    diesel_manual_override_enabled: dieselConfig.manual_override_enabled ? "true" : "false",
    fuel_surcharge_enabled: Number(settings.fuel_surcharge_enabled ?? 0) !== 0 ? "true" : "false",
    diesel_max_age_days: settings.diesel_max_age_days,
    vehicle_cost_profile_key: vehicle.vehicle_type,
    fuel_consumption_l_per_100km: vehicle.fuel_consumption_l_per_100km,
    average_tyre_cost_per_km: vehicle.average_tyre_cost_per_km,
    maintenance_cost_per_km: vehicle.maintenance_cost_per_km,
    insurance_cost_per_km: vehicle.insurance_cost_per_km,
    depreciation_cost_per_km: vehicle.depreciation_cost_per_km,
    vehicle_overhead_per_km: vehicle.vehicle_overhead_per_km,
    driver_hourly_wage: driver.driver_hourly_wage,
    driver_overnight_allowance: driver.driver_overnight_allowance,
    admin_overhead_percent: overhead.admin_overhead_percent,
    profit_margin_percent: overhead.profit_margin_percent,
    vat_percent: overhead.vat_percent,
    minimum_profit: overhead.minimum_profit,
    maximum_discount_percent: overhead.maximum_discount_percent,
    margin_profile_key: margin.margin_key,
    margin_profile_percent: margin.margin_percent,
    margin_profile_minimum_profit: margin.minimum_profit,
    ...settings
  };
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
