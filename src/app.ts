import {
  buildAdminDecisionEmail,
  buildClientQuoteEmail,
  buildRfqLinkEmail
} from "./emailPlaceholders";
import {
  applyEquipmentOverride,
  archiveQuoteRequest,
  autoRouteSubmittedRfq,
  createInternalRfqLink,
  generateQuotePdf,
  getInternalDocumentUrl,
  getPublicQuotePdfUrl,
  hasSupabaseSession,
  isSupabaseConfigured,
  listStandardEquipmentProfiles,
  listInternalUsers,
  loadCurrentInternalUser,
  loadAdminQuoteRequest,
  loadAdminQuoteRequests,
  loadCustomerPortal,
  loadInternalQuoteDocument,
  loadPublicQuoteDocument,
  loadPublicQuoteResponse,
  loadInternalSettings,
  recordPricingAdjustment,
  recordPricingComponentOverride,
  requestQuoteRevision,
  reactivateInternalUser,
  revokeInternalUser,
  savePricingSettings,
  saveInternalUser,
  sendQuoteEmail,
  signInInternalUser,
  signOutInternalUser,
  submitPublicQuoteDecision,
  submitPublicRfq,
  updateAdminQuote,
  updateInternalSettings,
  updateRouteEstimateGoogle,
  updateRouteEstimateManual
} from "./supabaseClient";
import type {
  CargoCategory,
  CustomerPortalRecord,
  InternalSettingsPayload,
  InternalUserRecord,
  InternalRole,
  InternalUser,
  LoadServiceType,
  PublicQuoteResponseRecord,
  PublicQuoteDocumentRecord,
  PricingAdjustmentRecord,
  PricingBreakdownRecord,
  PricingCalculationRecord,
  PricingComponentOverrideRecord,
  QuoteStopRecord,
  RfqDynamicAnswerRecord,
  QuoteItemRecord,
  QuoteRequest,
  QuoteRequestRecord,
  QuoteStatus,
  QuoteSuggestion,
  QuoteDocumentRecord,
  RouteEstimateRecord,
  RouteEstimateStopRecord,
  StandardEquipmentProfileRecord,
  TransportRequirementFlagRecord,
  TransportJobRecord,
  VehicleRecommendationRecord,
  SystemSettingRecord,
  EmailTemplatePlaceholderRecord,
  NumberingSequenceSettingRecord
} from "./types";

const storageKey = "time-trucking-auto-quote-batch-1";
const usersStorageKey = "time-trucking-auto-quote-internal-users";
const googleMapsApiKey = import.meta.env.VITE_GOOGLE_MAPS_API_KEY as string | undefined;
let googleMapsLoader: Promise<any> | null = null;
let currentInternalUser: InternalUserRecord | null = null;

const statusLabels: Record<QuoteStatus, string> = {
  draft: "Draft",
  rfq_submitted: "RFQ submitted",
  client_submitted: "Client submitted",
  admin_review: "Admin review",
  adjusted: "Adjusted",
  approved: "Approved",
  sent_to_client: "Sent to client",
  client_accepted: "Accepted",
  client_declined: "Declined - Review Required",
  expired: "Expired",
  converted_to_load: "Accepted Load"
};

function readRequests(): QuoteRequest[] {
  const raw = window.localStorage.getItem(storageKey);
  return raw ? (JSON.parse(raw) as QuoteRequest[]) : [];
}

function readInternalUsers(): InternalUser[] {
  const raw = window.localStorage.getItem(usersStorageKey);
  return raw ? (JSON.parse(raw) as InternalUser[]) : [];
}

function writeInternalUsers(users: InternalUser[]): void {
  window.localStorage.setItem(usersStorageKey, JSON.stringify(users));
}

function writeRequests(requests: QuoteRequest[]): void {
  window.localStorage.setItem(storageKey, JSON.stringify(requests));
}

function roleDescription(role: InternalRole): string {
  return {
    owner: "Full access, user management, approvals, pricing",
    manager: "RFQ management and quote approval",
    staff: "Assigned/internal quote access when allowed",
    viewer: "Read-only internal access"
  }[role];
}

function getRequest(id: string | null): QuoteRequest | undefined {
  return readRequests().find((request) => request.id === id);
}

function isInternalPage(): boolean {
  return ["dashboard", "create", "review", "users", "pricing", "admin-settings", "customers", "accepted-loads"].includes(document.body.dataset.page ?? "");
}

function isLoginPage(): boolean {
  return document.body.dataset.page === "login";
}

function loginRedirectUrl(): string {
  const pageName = window.location.pathname.split("/").pop() || "index.html";
  const target = `${pageName}${window.location.search}`;
  return `./login.html?redirect=${encodeURIComponent(target)}`;
}

function renderInternalGuard(message = "Internal login is required before manager pages can load."): boolean {
  if (!isInternalPage()) return true;
  const content = document.querySelector<HTMLElement>(".content");
  if (content) {
    content.innerHTML = `
      <section class="hero">
        <p class="eyebrow">Internal access required</p>
        <h1>Time Trucking login required</h1>
        <p class="muted">${escapeHtml(message)}</p>
      </section>
      <section class="card">
        <div class="card-heading"><h2>Protected Time Trucking portal</h2><span>Not public</span></div>
        <p class="muted">Public clients can only access secure customer pages. Internal dashboard, RFQ creation, quote review, approvals, accepted loads, customers, users, settings, audit logs, pricing, and quote data require approved Time Trucking login.</p>
        <a class="button primary" href="./login.html">Go to login</a>
      </section>
    `;
  }
  return false;
}

function renderAccessPending(message: string): void {
  const content = document.querySelector<HTMLElement>(".content");
  if (!content) return;
  content.innerHTML = `
    <section class="hero">
      <p class="eyebrow">Access pending</p>
      <h1>Internal access not active</h1>
      <p class="muted">${escapeHtml(message)}</p>
    </section>
    <section class="card">
      <div class="card-heading"><h2>Time Trucking access control</h2><span>Owner setup required</span></div>
        <p class="muted">Ask a Time Trucking owner to create or reactivate your portal access record. Public customer pages remain available without login.</p>
      <div class="button-row">
        <button type="button" id="accessPendingLogout">Sign out</button>
        <a class="button primary" href="./login.html">Back to login</a>
      </div>
    </section>
  `;
  document.querySelector<HTMLButtonElement>("#accessPendingLogout")?.addEventListener("click", async () => {
    if (isSupabaseConfigured) await signOutInternalUser();
    window.location.href = "./login.html";
  });
}

function userDisplayName(user: InternalUserRecord): string {
  return user.full_name || user.email;
}

function canAccessCurrentPage(user: InternalUserRecord): boolean {
  const page = document.body.dataset.page ?? "";
  if (page === "users") return user.role === "owner" || user.can_manage_users;
  if (page === "admin-settings") return ["owner", "manager"].includes(user.role) || user.can_manage_users || user.can_manage_rfqs;
  return true;
}

async function requireInternalAccess(): Promise<boolean> {
  if (!isInternalPage()) return true;
  if (!isSupabaseConfigured) return renderInternalGuard("The production backend is not configured. Add the Time Trucking app connection before using internal pages.");
  const hasSession = await hasSupabaseSession();
  if (!hasSession) {
    window.location.href = loginRedirectUrl();
    return false;
  }
  const user = await loadCurrentInternalUser();
  if (!user) {
    renderAccessPending("You are signed in, but your secure login does not have a matching Time Trucking portal access record yet.");
    return false;
  }
  if (user.user_status !== "active") {
    renderAccessPending("Your Time Trucking internal user access is revoked or inactive.");
    return false;
  }
  if (!canAccessCurrentPage(user)) {
    renderAccessPending("Your role does not allow access to this restricted internal page.");
    return false;
  }
  currentInternalUser = user;
  return true;
}

function currency(value: number | null): string {
  if (value === null) return "Pending";
  return new Intl.NumberFormat("en-ZA", {
    style: "currency",
    currency: "ZAR"
  }).format(value);
}

function formatDate(value: string | null): string {
  return value || "";
}

function quoteItemsFromRecord(record: QuoteRequestRecord | PublicQuoteResponseRecord): QuoteItemRecord[] {
  const items = record.quote_items;
  return Array.isArray(items) ? items : [];
}

function quoteStopsFromRecord(record: QuoteRequestRecord | PublicQuoteResponseRecord): QuoteStopRecord[] {
  const stops = record.quote_stops;
  return Array.isArray(stops) ? [...stops].sort((a, b) => a.stop_order - b.stop_order) : [];
}

function dynamicAnswersFromRecord(record: QuoteRequestRecord | PublicQuoteResponseRecord): RfqDynamicAnswerRecord[] {
  const answers = record.rfq_dynamic_answers;
  return Array.isArray(answers) ? answers : [];
}

function vehicleRecommendationFromRecord(record: QuoteRequestRecord): VehicleRecommendationRecord | undefined {
  const recommendations = record.vehicle_recommendations;
  return Array.isArray(recommendations) ? recommendations[0] : undefined;
}

function transportFlagsFromRecord(record: QuoteRequestRecord): TransportRequirementFlagRecord[] {
  const flags = record.transport_requirement_flags;
  return Array.isArray(flags) ? flags : [];
}

function routeEstimateFromRecord(record: QuoteRequestRecord): RouteEstimateRecord | undefined {
  const estimates = record.route_estimates;
  if (Array.isArray(estimates)) return estimates[0];
  return estimates && typeof estimates === "object" ? estimates : undefined;
}

function routeEstimateStopsFromRecord(record: QuoteRequestRecord): RouteEstimateStopRecord[] {
  const estimate = routeEstimateFromRecord(record);
  const stops = estimate?.route_estimate_stops;
  return Array.isArray(stops) ? [...stops].sort((a, b) => a.stop_order - b.stop_order) : [];
}

function pricingCalculationFromRecord(record: QuoteRequestRecord): PricingCalculationRecord | undefined {
  const calculations = record.pricing_calculations;
  return Array.isArray(calculations)
    ? [...calculations].sort((a, b) => String(b.calculation_timestamp).localeCompare(String(a.calculation_timestamp)))[0]
    : undefined;
}

function pricingBreakdownsFromRecord(record: QuoteRequestRecord): PricingBreakdownRecord[] {
  const calculation = pricingCalculationFromRecord(record);
  return Array.isArray(calculation?.pricing_breakdowns) ? calculation.pricing_breakdowns : [];
}

function pricingAdjustmentsFromRecord(record: QuoteRequestRecord): PricingAdjustmentRecord[] {
  const adjustments = record.pricing_adjustments;
  return Array.isArray(adjustments) ? adjustments : [];
}

function pricingComponentOverridesFromRecord(record: QuoteRequestRecord): PricingComponentOverrideRecord[] {
  const overrides = record.pricing_component_overrides;
  return Array.isArray(overrides) ? overrides : [];
}

function quoteDocumentsFromRecord(record: QuoteRequestRecord): QuoteDocumentRecord[] {
  const documents = record.quote_documents;
  return Array.isArray(documents)
    ? [...documents].sort((a, b) => b.version_number - a.version_number)
    : [];
}

function transportJobFromRecord(record: QuoteRequestRecord): TransportJobRecord | undefined {
  const jobs = record.transport_jobs;
  return Array.isArray(jobs) ? jobs[0] : undefined;
}

function requestFromRecord(record: QuoteRequestRecord): QuoteRequest {
  const items = quoteItemsFromRecord(record);
  const item = items[0];
  const stops = quoteStopsFromRecord(record);
  const firstCollection = stops.find((stop) => stop.stop_type === "collection") ?? stops[0];
  const firstDelivery = stops.find((stop) => stop.stop_type === "delivery") ?? stops[1];
  return {
    id: record.id,
    status: record.status,
    companyName: record.company_name,
    contactPerson: record.contact_person,
    email: record.email,
    phone: record.phone ?? "",
    collectionAddress: firstCollection?.address ?? record.collection_address,
    deliveryAddress: firstDelivery?.address ?? record.delivery_address,
    cargoType: record.cargo_type,
    loadDescription: record.load_description,
    quantity: item?.quantity ?? 1,
    length: item?.length_m ?? 0,
    width: item?.width_m ?? 0,
    height: item?.height_m ?? 0,
    weight: item ? itemTotalWeightKg(item) : 0,
    stackable: record.stackable,
    loadType: record.load_type,
    loadingMethod: record.loading_method ?? "",
    offloadingMethod: record.offloading_method ?? "",
    goodsValue: record.goods_value ?? 0,
    insurance: record.insurance_required,
    collectionDate: formatDate(record.collection_date),
    deliveryDate: formatDate(record.delivery_date),
    specialRequirements: record.special_requirements ?? "",
    attachmentNote: record.attachment_note ?? "",
    suggestedVehicle: "Vehicle recommendation",
    suggestedTrailer: record.suggestion_notes ?? "Trailer recommendation pending",
    adminNotes: record.admin_notes ?? "",
    quotePrice: record.adjusted_price,
    publicReference: record.public_reference ?? "",
    stops,
    items,
    dynamicAnswers: dynamicAnswersFromRecord(record),
    vehicleRecommendation: vehicleRecommendationFromRecord(record),
    transportFlags: transportFlagsFromRecord(record),
    routeEstimate: routeEstimateFromRecord(record),
    routeEstimateStops: routeEstimateStopsFromRecord(record),
    pricingCalculation: pricingCalculationFromRecord(record),
    pricingBreakdowns: pricingBreakdownsFromRecord(record),
    pricingAdjustments: pricingAdjustmentsFromRecord(record),
    pricingComponentOverrides: pricingComponentOverridesFromRecord(record),
    quoteDocuments: quoteDocumentsFromRecord(record),
    transportJob: transportJobFromRecord(record),
    createdAt: record.created_at
  };
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => {
    const map: Record<string, string> = {
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      "\"": "&quot;",
      "'": "&#039;"
    };
    return map[character];
  });
}

function friendlyError(error: unknown, fallback = "Something went wrong while contacting Time Trucking Auto-Quote. Please check your connection and try again."): string {
  if (!(error instanceof Error) || !error.message.trim()) return fallback;
  const message = error.message.trim();
  if (/PGRST|SQLSTATE|postgres|PostgREST|Edge Function|stack|rpc/i.test(message)) {
    return "The workflow could not complete. Please refresh and try again, or ask an owner to review the quote state.";
  }
  if (message.toLowerCase().includes("jwt") || message.toLowerCase().includes("permission") || message.toLowerCase().includes("not authorized")) {
    return `${message} Please sign in with an approved Time Trucking internal account.`;
  }
  if (message.toLowerCase().includes("fetch") || message.toLowerCase().includes("network")) {
    return "The system could not reach Supabase. Please check the internet connection and try again.";
  }
  return message;
}

function calculateSuggestion(data: {
  quantity: number;
  length: number;
  width: number;
  height: number;
  weight: number;
  stackable: boolean;
  loadType: LoadServiceType;
  insurance: boolean;
}): QuoteSuggestion {
  const totalWeight = data.quantity * data.weight;
  const totalCube = data.quantity * data.length * data.width * data.height;
  let suggestedVehicle = "1-ton bakkie / panel van";
  let suggestedTrailer = "Closed body";

  if (totalWeight > 1200 || totalCube > 8) {
    suggestedVehicle = "4-ton truck";
    suggestedTrailer = data.stackable ? "Curtain side body" : "Box body with floor-space review";
  }

  if (totalWeight > 4000 || totalCube > 28) {
    suggestedVehicle = "8-ton truck";
    suggestedTrailer = "Tautliner";
  }

  if (data.loadType === "dedicated" || totalWeight > 9000 || totalCube > 60) {
    suggestedVehicle = "Dedicated truck";
    suggestedTrailer = "Superlink / tautliner review";
  }

  const notes = [
    `Estimated total weight: ${totalWeight || 0} kg.`,
    `Estimated cube: ${Number.isFinite(totalCube) ? totalCube.toFixed(2) : "0.00"} m3.`,
    data.stackable ? "Cargo marked stackable." : "Cargo marked not stackable.",
    data.insurance ? "Insurance requested." : "Insurance not requested."
  ].join(" ");

  return { suggestedVehicle, suggestedTrailer, notes };
}

function calculateWizardSuggestion(items: QuoteItemRecord[], loadType: LoadServiceType, insurance: boolean): QuoteSuggestion {
  const totalWeight = items.reduce((sum, item) => sum + itemTotalWeightKg(item), 0);
  const totalCube = items.reduce(
    (sum, item) => sum + (item.quantity || 1) * (item.length_m ?? 0) * (item.width_m ?? 0) * (item.height_m ?? 0),
    0
  );
  const hasDangerous = items.some((item) => item.dangerous_goods || item.cargo_category === "dangerous_goods");
  const hasRefrigerated = items.some((item) => item.temperature_controlled || item.cargo_category === "refrigerated");
  const hasMachinery = items.some((item) => item.cargo_category === "machinery");
  const hasFragile = items.some((item) => item.fragile);

  let suggestedVehicle = "1-ton bakkie / panel van";
  let suggestedTrailer = "Closed body";

  if (totalWeight > 1200 || totalCube > 8 || items.length > 1) {
    suggestedVehicle = "4-ton truck";
    suggestedTrailer = "Curtain side or box body";
  }
  if (totalWeight > 4000 || totalCube > 28) {
    suggestedVehicle = "8-ton truck";
    suggestedTrailer = "Tautliner";
  }
  if (loadType === "dedicated" || totalWeight > 9000 || totalCube > 60) {
    suggestedVehicle = "Dedicated truck";
    suggestedTrailer = "Superlink / tautliner review";
  }
  if (hasRefrigerated) suggestedTrailer = "Refrigerated vehicle review";
  if (hasDangerous) suggestedTrailer = "Dangerous goods compliant vehicle review";
  if (hasMachinery) suggestedTrailer = "Flatdeck / lowbed / crane review";

  return {
    suggestedVehicle,
    suggestedTrailer,
    notes: [
      `Items: ${items.length}.`,
      `Estimated total weight: ${totalWeight || 0} kg.`,
      `Estimated cube: ${Number.isFinite(totalCube) ? totalCube.toFixed(2) : "0.00"} m3.`,
      hasFragile ? "Fragile handling flagged." : "No fragile flag.",
      hasDangerous ? "Dangerous goods review required." : "No dangerous goods flag.",
      hasRefrigerated ? "Temperature control review required." : "No temperature control flag.",
      insurance ? "Insurance requested." : "Insurance not requested."
    ].join(" ")
  };
}

function calculateVehicleIntelligence(items: QuoteItemRecord[]): {
  recommendation: VehicleRecommendationRecord;
  flags: TransportRequirementFlagRecord[];
} {
  const totalWeight = items.reduce((sum, item) => sum + itemTotalWeightKg(item), 0);
  const totalVolume = items.reduce((sum, item) => sum + (item.quantity || 1) * (item.length_m ?? 0) * (item.width_m ?? 0) * (item.height_m ?? 0), 0);
  const totalDeckArea = items.reduce((sum, item) => sum + (item.quantity || 1) * (item.length_m ?? 0) * (item.width_m ?? 0), 0);
  const maxLength = Math.max(0, ...items.map((item) => item.length_m ?? 0));
  const maxWidth = Math.max(0, ...items.map((item) => item.width_m ?? 0));
  const maxHeight = Math.max(0, ...items.map((item) => item.height_m ?? 0));
  const totalValue = items.reduce((sum, item) => sum + (item.cargo_value ?? 0), 0);
  const itemCount = items.reduce((sum, item) => sum + (item.quantity || 1), 0);
  const hazmat = items.some((item) => item.dangerous_goods || item.cargo_category === "dangerous_goods");
  const refrigerated = items.some((item) => item.temperature_controlled || item.cargo_category === "refrigerated");
  const machinery = items.some((item) => item.cargo_category === "machinery");
  const fragile = items.some((item) => item.fragile);
  const missingRequiredDimensions = items.some((item) =>
    item.cargo_category === "machinery" && (!(item.length_m ?? 0) || !(item.width_m ?? 0) || !(item.height_m ?? 0))
  );
  const dimensionallyAbnormal = maxLength > 12 || maxWidth > 2.5 || maxHeight > 4.3;
  const crane = machinery && totalWeight > 8000;
  const forklift = !machinery && totalWeight > 1000;

  let vehicle = "8 ton / 14 ton";
  let trailer = "Curtain side";
  let payloadCapacity = 8000;
  let volumeCapacity = 45;

  if (refrigerated) {
    vehicle = "Refrigerated vehicle";
    trailer = "Refrigerated trailer";
    payloadCapacity = 28000;
    volumeCapacity = 85;
  } else if (hazmat) {
    vehicle = "Hazmat-capable vehicle";
    trailer = "Hazmat-compatible trailer";
    payloadCapacity = 28000;
    volumeCapacity = 85;
  } else if (dimensionallyAbnormal || (machinery && (totalWeight > 28000 || maxLength > 12))) {
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

  const trucks = Math.max(1, Math.ceil(Math.max(totalWeight / payloadCapacity, totalVolume / volumeCapacity)));
  const managerReview = dimensionallyAbnormal || missingRequiredDimensions || hazmat || refrigerated || crane || totalValue >= 500000 || fragile;
  const makeFlag = (key: string, label: string, severity: string, notes: string): TransportRequirementFlagRecord => ({
    id: key,
    quote_request_id: "",
    vehicle_recommendation_id: null,
    flag_key: key,
    flag_label: label,
    severity,
    flag_notes: notes
  });
  const flags = [
    missingRequiredDimensions ? makeFlag("dimensions_required", "Dimensions required", "warning", "Length, width, and height are required before abnormal-load review.") : null,
    dimensionallyAbnormal ? makeFlag("abnormal_load", "Abnormal load", "warning", "Dimensions may exceed normal transport limits.") : null,
    dimensionallyAbnormal ? makeFlag("permit_required", "Permit required", "warning", "Permit review recommended for abnormal dimensions.") : null,
    maxWidth > 3.5 || maxLength > 22 ? makeFlag("escort_recommended", "Escort recommended", "warning", "Escort vehicle may be required.") : null,
    hazmat ? makeFlag("hazmat_required", "Hazmat required", "critical", "Dangerous goods handling required.") : null,
    refrigerated ? makeFlag("refrigeration_required", "Refrigeration required", "warning", "Temperature-controlled equipment required.") : null,
    crane ? makeFlag("crane_required", "Crane required", "warning", "Crane loading/offloading review required.") : null,
    forklift ? makeFlag("forklift_required", "Forklift required", "info", "Forklift loading/offloading likely required.") : null,
    managerReview ? makeFlag("manager_review_required", "Manager review required", "critical", "Manager review required before quote.") : null
  ].filter(Boolean) as TransportRequirementFlagRecord[];

  return {
    recommendation: {
      id: "local-vehicle-intelligence",
      quote_request_id: "",
      recommended_vehicle_type: vehicle,
      recommended_trailer_type: trailer,
      number_of_trucks: trucks,
      estimated_payload_utilization_percent: Math.min(100, Math.round((totalWeight / (payloadCapacity * trucks)) * 100)),
      estimated_volume_utilization_percent: Math.min(100, Math.round((totalVolume / (volumeCapacity * trucks)) * 100)),
      abnormal_load: dimensionallyAbnormal,
      permit_required: dimensionallyAbnormal,
      escort_recommended: maxWidth > 3.5 || maxLength > 22,
      hazmat_required: hazmat,
      refrigeration_required: refrigerated,
      crane_required: crane,
      forklift_required: forklift,
      manager_review_required: managerReview,
      recommendation_notes: [
        `${itemCount} item(s), total weight ${formatKg(totalWeight)} kg.`,
        `Deck footprint ${totalDeckArea.toFixed(2)} m2 and cube ${totalVolume.toFixed(2)} m3.`,
        `Largest item ${maxLength}m x ${maxWidth}m x ${maxHeight}m.`,
        dimensionallyAbnormal ? "Abnormal dimension review required." : "No abnormal dimensions detected by the current configured rule.",
        missingRequiredDimensions ? "Dimensions are missing and manager review is required before relying on this recommendation." : "",
        `${trucks} truck(s) based on payload and cube capacity.`
      ].filter(Boolean).join(" "),
      override_vehicle_type: null,
      override_trailer_type: null,
      override_reason: null
    },
    flags
  };
}

function renderVehicleIntelligenceCard(request: QuoteRequest): string {
  const fallback = calculateVehicleIntelligence(request.items ?? []);
  const recommendation = request.vehicleRecommendation ?? fallback.recommendation;
  const flags = request.transportFlags?.length ? request.transportFlags : fallback.flags;
  const activeVehicle = recommendation.override_vehicle_type || recommendation.recommended_vehicle_type;
  const activeTrailer = recommendation.override_trailer_type || recommendation.recommended_trailer_type;
  const source = equipmentSourceLabel(recommendation.equipment_source);
  const reasoning = Array.isArray(recommendation.recommendation_reasoning)
    ? recommendation.recommendation_reasoning.filter(Boolean)
    : [];
  const alternatives = Array.isArray(recommendation.equipment_alternatives)
    ? recommendation.equipment_alternatives
    : [];
  const overrideHistory = Array.isArray(recommendation.equipment_override_history)
    ? recommendation.equipment_override_history.slice(-3).reverse()
    : [];
  return `
    <section class="vehicle-intelligence-card">
      <div class="card-heading">
        <h2>Vehicle Intelligence</h2>
        <span>${recommendation.manager_review_required ? "Manager review required" : "Ready for pricing review"}</span>
      </div>
      <div class="grid three">
        <p><strong>Recommended equipment</strong><span>${escapeHtml(activeVehicle)}</span></p>
        <p><strong>Trailer/body</strong><span>${escapeHtml(activeTrailer)}</span></p>
        <p><strong>Units</strong><span>${recommendation.number_of_trucks}</span></p>
        <p><strong>Equipment source</strong><span>${escapeHtml(source)}</span></p>
        <p><strong>Payload utilisation</strong><span>${formatPercent(recommendation.estimated_payload_utilization_percent)}</span></p>
        <p><strong>Volume utilisation</strong><span>${formatPercent(recommendation.estimated_volume_utilization_percent)}</span></p>
        <p><strong>Deck utilisation</strong><span>${formatPercent(recommendation.estimated_deck_utilization_percent)}</span></p>
        <p><strong>Override</strong><span>${recommendation.override_reason ? escapeHtml(recommendation.override_reason) : "System recommendation active"}</span></p>
      </div>
      ${
        reasoning.length
          ? `<div class="summary-block"><h3>Why this recommendation</h3><ul class="compact-list">${reasoning.map((reason) => `<li>${escapeHtml(String(reason))}</li>`).join("")}</ul></div>`
          : ""
      }
      ${
        alternatives.length
          ? `<div class="summary-block"><h3>Alternatives</h3><div class="equipment-alt-list">${alternatives.map((profile) => `<span>${escapeHtml(profile.display_name)} - ${escapeHtml(profile.trailer_body)} - ${profile.units} unit(s)</span>`).join("")}</div></div>`
          : ""
      }
      ${
        overrideHistory.length
          ? `<div class="summary-block"><h3>Override history</h3><div class="equipment-alt-list">${overrideHistory.map((entry) => `<span>${escapeHtml(equipmentHistoryLabel(entry))}</span>`).join("")}</div></div>`
          : ""
      }
      <div class="flag-row">
        ${
          flags.length
            ? flags.map((flag) => `<span class="flag ${escapeHtml(flag.severity)}">${escapeHtml(flag.flag_label)}</span>`).join("")
            : `<span class="flag info">No warning flags</span>`
        }
      </div>
      <p class="muted">${escapeHtml(recommendation.recommendation_notes ?? "No recommendation notes captured.")}</p>
      <div class="equipment-override-panel" id="equipmentOverridePanel">
        <div>
          <strong>Henning equipment review</strong>
          <span>Override the selected vehicle/equipment only when operational judgement differs from the system recommendation. Pricing recalculates after save.</span>
        </div>
        <div class="grid three">
          <label>Equipment profile
            <select id="equipmentProfileSelect" data-current-profile="${escapeHtml(recommendation.final_equipment_profile_id ?? "")}">
              <option value="">Loading equipment profiles...</option>
            </select>
          </label>
          <label>Units
            <input id="equipmentUnitCount" type="number" min="1" step="1" value="${recommendation.number_of_trucks}">
          </label>
          <label>Source
            <select id="equipmentSourceSelect">
              <option value="either"${recommendation.equipment_source === "either" || !recommendation.equipment_source ? " selected" : ""}>Either / not decided</option>
              <option value="own_fleet"${recommendation.equipment_source === "own_fleet" ? " selected" : ""}>Own fleet</option>
              <option value="subcontractor"${recommendation.equipment_source === "subcontractor" ? " selected" : ""}>Subcontractor</option>
            </select>
          </label>
        </div>
        <label>Override reason
          <textarea id="equipmentOverrideReason" rows="2" placeholder="Required when overriding equipment">${escapeHtml(recommendation.override_reason ?? "")}</textarea>
        </label>
        <div class="button-row">
          <button class="primary" type="button" id="applyEquipmentOverrideButton">Apply equipment override</button>
          <button type="button" id="resetEquipmentOverrideButton">Reset to system</button>
        </div>
      </div>
    </section>
  `;
}

function equipmentSourceLabel(source: string | null | undefined): string {
  if (source === "own_fleet") return "Own fleet";
  if (source === "subcontractor") return "Subcontractor";
  return "Either / not decided";
}

function humanizeKey(value: string | null | undefined, fallback = "Not available"): string {
  if (!value) return fallback;
  return value
    .replaceAll("_", " ")
    .replaceAll("-", " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, (character) => character.toUpperCase());
}

function formatPercent(value: number | null | undefined): string {
  if (!Number.isFinite(Number(value))) return "0%";
  return `${Number(value).toFixed(2).replace(/\.00$/, "")}%`;
}

function equipmentHistoryLabel(entry: {
  action?: unknown;
  to_equipment?: unknown;
  from_units?: unknown;
  to_units?: unknown;
  reason?: unknown;
  timestamp?: unknown;
}): string {
  const action = String(entry.action ?? "override").replaceAll("_", " ");
  const toEquipment = String(entry.to_equipment ?? "system recommendation");
  const fromUnits = Number(entry.from_units ?? 0);
  const toUnits = Number(entry.to_units ?? 0);
  const unitText = fromUnits || toUnits ? ` (${fromUnits || "?"} -> ${toUnits || "?"} unit(s))` : "";
  const reason = String(entry.reason ?? "No reason captured");
  const timestamp = entry.timestamp ? ` - ${formatDateTime(String(entry.timestamp))}` : "";
  return `${action}: ${toEquipment}${unitText}. ${reason}${timestamp}`;
}

async function hydrateEquipmentOverrideControls(request: QuoteRequest, canEdit: boolean, output: HTMLElement): Promise<void> {
  const profileSelect = document.querySelector<HTMLSelectElement>("#equipmentProfileSelect");
  const unitInput = document.querySelector<HTMLInputElement>("#equipmentUnitCount");
  const sourceSelect = document.querySelector<HTMLSelectElement>("#equipmentSourceSelect");
  const reasonInput = document.querySelector<HTMLTextAreaElement>("#equipmentOverrideReason");
  const applyButton = document.querySelector<HTMLButtonElement>("#applyEquipmentOverrideButton");
  const resetButton = document.querySelector<HTMLButtonElement>("#resetEquipmentOverrideButton");
  if (!profileSelect || !unitInput || !sourceSelect || !reasonInput || !applyButton || !resetButton) return;

  const setDisabled = (disabled: boolean): void => {
    profileSelect.disabled = disabled;
    unitInput.disabled = disabled;
    sourceSelect.disabled = disabled;
    reasonInput.disabled = disabled;
    applyButton.disabled = disabled;
    resetButton.disabled = disabled;
  };

  if (!isSupabaseConfigured) {
    profileSelect.innerHTML = `<option value="">Connect Supabase to load equipment profiles</option>`;
    setDisabled(true);
    return;
  }

  setDisabled(!canEdit);
  try {
    const profiles = await listStandardEquipmentProfiles();
    const currentProfileId = profileSelect.dataset.currentProfile ?? "";
    profileSelect.innerHTML = profiles.length
      ? profiles.map((profile) => `<option value="${escapeHtml(profile.id)}"${profile.id === currentProfileId ? " selected" : ""}>${escapeHtml(profile.display_name)} - ${escapeHtml(profile.trailer_body)} - ${formatKg(Number(profile.payload_capacity_kg ?? 0))} kg</option>`).join("")
      : `<option value="">No active equipment profiles found</option>`;
  } catch (error) {
    profileSelect.innerHTML = `<option value="">Equipment profiles could not load</option>`;
    output.innerHTML = `<strong>Equipment profiles unavailable.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
  }

  const refreshEquipmentAndPricing = async (message: string): Promise<void> => {
    const record = await loadAdminQuoteRequest(request.id);
    if (!record) throw new Error("Quote could not be reloaded after recalculation.");
    const freshRequest = requestFromRecord(record);
    const vehicleCard = document.querySelector<HTMLElement>(".vehicle-intelligence-card");
    const pricingCard = document.querySelector<HTMLElement>(".pricing-summary-card");
    if (vehicleCard) vehicleCard.outerHTML = renderVehicleIntelligenceCard(freshRequest);
    if (pricingCard) pricingCard.outerHTML = renderPricingSummaryCard(freshRequest);
    const quotePriceInput = document.querySelector<HTMLInputElement>("[name='quotePrice']");
    if (quotePriceInput) quotePriceInput.value = String(freshRequest.quotePrice ?? freshRequest.pricingCalculation?.recommended_selling_price ?? "");
    output.innerHTML = message;
    await hydrateEquipmentOverrideControls(freshRequest, canEdit, output);
  };

  applyButton.addEventListener("click", async () => {
    const equipmentProfileId = profileSelect.value || null;
    const unitCount = Number(unitInput.value);
    const overrideReason = reasonInput.value.trim();
    if (!equipmentProfileId) {
      output.innerHTML = `<strong>Equipment override blocked.</strong><span>Select an active equipment profile.</span>`;
      return;
    }
    if (!Number.isFinite(unitCount) || unitCount < 1) {
      output.innerHTML = `<strong>Equipment override blocked.</strong><span>Enter at least one vehicle unit.</span>`;
      return;
    }
    if (!overrideReason) {
      output.innerHTML = `<strong>Equipment override blocked.</strong><span>Add the operational reason for the override.</span>`;
      reasonInput.focus();
      return;
    }
    try {
      output.innerHTML = `<strong>Recalculating...</strong><span>Updating equipment, unit count, and pricing.</span>`;
      applyButton.disabled = true;
      await applyEquipmentOverride({
        quoteRequestId: request.id,
        equipmentProfileId,
        unitCount,
        equipmentSource: sourceSelect.value as "own_fleet" | "subcontractor" | "either",
        overrideReason
      });
      await refreshEquipmentAndPricing(`<strong>Price updated.</strong><span>Selected equipment, unit count, and pricing are now in sync.</span>`);
    } catch (error) {
      output.innerHTML = `<strong>Equipment override failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
      applyButton.disabled = false;
    }
  });

  resetButton.addEventListener("click", async () => {
    const unitCount = Number(unitInput.value);
    try {
      output.innerHTML = `<strong>Recalculating...</strong><span>Restoring the system equipment recommendation.</span>`;
      resetButton.disabled = true;
      await applyEquipmentOverride({
        quoteRequestId: request.id,
        equipmentProfileId: null,
        unitCount: Number.isFinite(unitCount) && unitCount > 0 ? unitCount : request.vehicleRecommendation?.number_of_trucks ?? 1,
        equipmentSource: "either",
        overrideReason: "Reset to system recommendation"
      });
      await refreshEquipmentAndPricing(`<strong>System recommendation restored.</strong><span>Pricing now follows the system-selected equipment.</span>`);
    } catch (error) {
      output.innerHTML = `<strong>Reset failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
      resetButton.disabled = false;
    }
  });
}

function renderRouteIntelligenceCard(request: QuoteRequest): string {
  const estimate = request.routeEstimate;
  const routeStops = request.routeEstimateStops?.length
    ? request.routeEstimateStops
    : (request.stops ?? []).map((stop) => ({
        id: stop.id,
        route_estimate_id: "",
        quote_request_id: stop.quote_request_id,
        quote_stop_id: stop.id,
        stop_order: stop.stop_order,
        stop_type: stop.stop_type,
        address: stop.address,
        latitude: null,
        longitude: null,
        geocoded: false,
        provider_stop_id: null,
        place_id: null,
        formatted_address: null,
        created_at: ""
      }));
  const providerLabel = estimate?.provider_name === "manual_placeholder"
    ? "Manual estimate"
    : estimate?.provider_name ?? "Manual estimate";
  const distance = estimate?.manual_distance_km ?? estimate?.total_distance_km ?? 0;
  const duration = estimate?.manual_duration_hours ?? estimate?.total_duration_hours ?? 0;
  const routeAddresses = routeAddressesForQuote(request);
  const mapsUrl = estimate?.google_maps_url ?? googleMapsDirectionsUrl(routeAddresses);
  const googleReadyLabel = googleMapsApiKey ? "Google Maps estimate available" : "Add Google Maps API key to enable automatic route estimate";
  const providerResponse = estimate?.provider_response ?? {};
  const tollStatus = dynamicValue(providerResponse, "toll_status", estimate?.provider_name === "google_maps" ? "unavailable" : "estimated/manual fallback");
  const riskStatus = dynamicValue(providerResponse, "route_risk_status", "default/manual pricing rules");
  const calculatedAt = estimate?.estimated_at ?? dynamicValue(providerResponse, "calculated_at", "Not calculated yet");
  const sourceLabel = estimate?.manual_distance_km || estimate?.manual_duration_hours
    ? "Manual override"
    : estimate?.provider_name === "google_maps"
      ? "Live Google Maps"
      : "Manual fallback";

  return `
    <section class="route-intelligence-card">
      <div class="card-heading">
        <h2>Route Intelligence</h2>
        <span>${escapeHtml(sourceLabel)} - ${escapeHtml(humanizeKey(estimate?.confidence_level ?? "manual"))}</span>
      </div>
      <div class="grid three">
        <p><strong>Origin</strong><span>${escapeHtml(estimate?.origin_address ?? request.collectionAddress)}</span></p>
        <p><strong>Destination</strong><span>${escapeHtml(estimate?.destination_address ?? request.deliveryAddress)}</span></p>
        <p><strong>Estimate</strong><span>${formatDistanceKm(distance)} / ${formatDurationHours(duration)}</span></p>
        <p><strong>Stop count</strong><span>${routeStops.length || routeAddresses.length}</span></p>
        <p><strong>Calculated</strong><span>${escapeHtml(formatDateTime(calculatedAt))}</span></p>
        <p><strong>Source</strong><span>${escapeHtml(humanizeKey(providerLabel))}</span></p>
        <p><strong>Tolls</strong><span>${escapeHtml(humanizeKey(tollStatus))}</span></p>
        <p><strong>Route risk</strong><span>${escapeHtml(humanizeKey(riskStatus))}</span></p>
        <p><strong>Override</strong><span>${estimate?.manually_overridden_at ? `Overridden ${escapeHtml(formatDateTime(estimate.manually_overridden_at))}` : "No manual override"}</span></p>
      </div>
      ${renderRouteMapPreview(request)}
      <div class="summary-block">
        <h3>Route stops</h3>
        ${
          routeStops.length
            ? routeStops.map((stop) => `<p><strong>${stop.stop_order}. ${escapeHtml(String(stop.stop_type ?? "stop"))}</strong><span>${escapeHtml(stop.formatted_address ?? stop.address)}${stop.place_id ? ` - Place ID stored` : ""}</span></p>`).join("")
            : `<p class="muted">Stops will appear here after RFQ submission.</p>`
        }
      </div>
      <div class="grid three">
        <label>Distance km
          <input name="routeDistanceKm" type="number" step="0.1" min="0" value="${distance}">
        </label>
        <label>Duration hours
          <input name="routeDurationHours" type="number" step="0.1" min="0" value="${duration}">
        </label>
        <label>Override reason
          <input name="routeOverrideReason" value="${escapeHtml(estimate?.manual_override_reason ?? "")}" placeholder="Manual estimate">
        </label>
      </div>
      <div class="button-row">
        <button type="button" id="googleRouteEstimateButton">Calculate Route</button>
        <button class="primary" type="button" id="regeneratePricingButton">Update pricing</button>
        ${mapsUrl ? `<a class="button small" href="${escapeHtml(mapsUrl)}" target="_blank" rel="noopener noreferrer">Open in Google Maps</a>` : ""}
        <span class="muted">${escapeHtml(googleReadyLabel)}. Manual fallback remains available.</span>
      </div>
      <p class="muted">${escapeHtml(estimate?.route_notes ?? "Route distance and duration feed the pricing engine.")}</p>
      ${estimate?.provider_error ? `<p class="muted"><strong>Provider note:</strong> ${escapeHtml(estimate.provider_error)}</p>` : ""}
    </section>
  `;
}

function money(value: number | null | undefined, currencyCode = "ZAR"): string {
  return new Intl.NumberFormat("en-ZA", {
    style: "currency",
    currency: currencyCode,
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  }).format(value ?? 0).replace(/\u00a0/g, " ");
}

function formatNumber(value: number | null | undefined, maximumFractionDigits = 1): string {
  return new Intl.NumberFormat("en-ZA", {
    maximumFractionDigits,
    minimumFractionDigits: 0
  }).format(Number(value ?? 0)).replace(/\u00a0/g, " ");
}

function formatDistanceKm(value: number | null | undefined): string {
  return `${formatNumber(value, 1)} km`;
}

function formatDurationHours(value: number | null | undefined): string {
  const totalMinutes = Math.round(Number(value ?? 0) * 60);
  if (!Number.isFinite(totalMinutes) || totalMinutes <= 0) return "0 h";
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return minutes ? `${hours} h ${minutes} min` : `${hours} h`;
}

function routeAddressesForQuote(request: QuoteRequest): string[] {
  const stopAddresses = (request.stops ?? [])
    .slice()
    .sort((a, b) => a.stop_order - b.stop_order)
    .map((stop) => stop.address.trim())
    .filter(Boolean);
  if (stopAddresses.length >= 2) return stopAddresses;
  return [request.collectionAddress, request.deliveryAddress].map((address) => address.trim()).filter(Boolean);
}

function googleMapsDirectionsUrl(addresses: string[]): string {
  if (addresses.length < 2) return "";
  const params = new URLSearchParams({
    api: "1",
    origin: addresses[0],
    destination: addresses[addresses.length - 1],
    travelmode: "driving"
  });
  const waypoints = addresses.slice(1, -1);
  if (waypoints.length) params.set("waypoints", waypoints.join("|"));
  return `https://www.google.com/maps/dir/?${params.toString()}`;
}

function googleMapsMissingKeyMessage(): string {
  return "Google Maps API key is missing. Add VITE_GOOGLE_MAPS_API_KEY to the environment and restart the dev server.";
}

function ensureGoogleMapsLoaded(): Promise<any> {
  if (!googleMapsApiKey) {
    return Promise.reject(new Error(googleMapsMissingKeyMessage()));
  }
  const googleRef = (window as unknown as { google?: any }).google ?? ((window as unknown as { google?: any }).google = {});
  const mapsRef = googleRef.maps ?? (googleRef.maps = {});
  if (typeof mapsRef.importLibrary === "function") return Promise.resolve(mapsRef);
  if (googleMapsLoader) return googleMapsLoader;
  googleMapsLoader = new Promise((resolve, reject) => {
    const callbackName = "__ttaqGoogleMapsReady";
    mapsRef[callbackName] = () => {
      if (typeof mapsRef.importLibrary === "function") {
        resolve(mapsRef);
        return;
      }
      reject(new Error("Google Maps library loader is not available."));
    };
    const script = document.createElement("script");
    script.dataset.ttaqGoogleMaps = "true";
    script.async = true;
    script.defer = true;
    const params = new URLSearchParams({
      key: googleMapsApiKey,
      v: "weekly",
      loading: "async",
      callback: `google.maps.${callbackName}`
    });
    script.src = `https://maps.googleapis.com/maps/api/js?${params.toString()}`;
    script.addEventListener("error", () => reject(new Error("Google Maps script could not load.")), { once: true });
    document.head.appendChild(script);
  });
  return googleMapsLoader;
}

async function loadGoogleMapsLibrary<TLibrary>(libraryName: string): Promise<TLibrary> {
  const maps = await ensureGoogleMapsLoaded();
  if (typeof maps.importLibrary !== "function") throw new Error("Google Maps library loader is not available.");
  return maps.importLibrary(libraryName) as Promise<TLibrary>;
}

function renderRouteMapPreview(request: QuoteRequest): string {
  const addresses = routeAddressesForQuote(request);
  const mapLink = request.routeEstimate?.google_maps_url ?? googleMapsDirectionsUrl(addresses);
  return `
    <div class="route-map-preview" id="routeMapPreview">
      <div class="route-map-canvas" id="routeMapCanvas"></div>
      <div class="route-map-fallback">
        <strong>Route map preview</strong>
        <span>${googleMapsApiKey ? "Loading Google route preview..." : escapeHtml(googleMapsMissingKeyMessage())}</span>
        ${mapLink ? `<a href="${escapeHtml(mapLink)}" target="_blank" rel="noopener noreferrer">Open in Google Maps</a>` : ""}
      </div>
    </div>
  `;
}

async function hydrateRouteMapPreview(request: QuoteRequest): Promise<void> {
  const preview = document.querySelector<HTMLElement>("#routeMapPreview");
  const canvas = document.querySelector<HTMLElement>("#routeMapCanvas");
  const fallback = preview?.querySelector<HTMLElement>(".route-map-fallback");
  if (!preview || !canvas) return;

  const addresses = routeAddressesForQuote(request);
  if (addresses.length < 2) {
    const span = fallback?.querySelector("span");
    if (span) span.textContent = "Add at least one collection and one delivery stop to preview the route.";
    return;
  }

  try {
    const [maps, core] = await Promise.all([
      loadGoogleMapsLibrary<{ Map: any; Polyline: any }>("maps"),
      loadGoogleMapsLibrary<{ LatLngBounds: any }>("core")
    ]);
    const storedPath = request.routeEstimate?.provider_response?.path as Array<{ latitude: number; longitude: number }> | undefined;
    const routeEstimate = storedPath?.length ? null : await estimateRouteWithGoogleMaps(addresses);
    const path = storedPath?.length ? storedPath : routeEstimate?.providerResponse?.path as Array<{ latitude: number; longitude: number }> | undefined;
    const map = new maps.Map(canvas, {
      zoom: 6,
      center: { lat: -28.5, lng: 24.5 },
      mapTypeControl: false,
      streetViewControl: false,
      fullscreenControl: false
    });
    const previewPath = path?.length ? path.map((point) => ({ lat: point.latitude, lng: point.longitude })) : [];
    if (!previewPath.length) throw new Error("Google Maps returned no route path to render.");
    const bounds = new core.LatLngBounds();
    previewPath.forEach((point) => bounds.extend(point));
    new maps.Polyline({
      map,
      path: previewPath,
      strokeColor: "#2563eb",
      strokeOpacity: 0.9,
      strokeWeight: 5
    });
    map.fitBounds(bounds);
    preview.classList.add("is-loaded");
  } catch (error) {
    const span = fallback?.querySelector("span");
    if (span) span.textContent = friendlyError(error, "Route preview is unavailable. Use the Google Maps link or manual fallback.");
  }
}

async function estimateRouteWithGoogleMaps(addresses: string[]): Promise<{
  distanceKm: number;
  durationHours: number;
  googleMapsUrl: string;
  providerResponse: Record<string, unknown>;
}> {
  if (addresses.length < 2) throw new Error("At least one pickup and one delivery address are required for Google Maps routing.");
  const routes = await loadGoogleMapsLibrary<{ Route: any; ComputeRoutesExtraComputation?: Record<string, string> }>("routes");
  const result = await routes.Route.computeRoutes({
    origin: addresses[0],
    destination: addresses[addresses.length - 1],
    intermediates: addresses.slice(1, -1).map((location) => ({ location })),
    travelMode: "DRIVING",
    routingPreference: "TRAFFIC_UNAWARE",
    extraComputations: routes.ComputeRoutesExtraComputation?.TOLLS ? [routes.ComputeRoutesExtraComputation.TOLLS] : undefined,
    fields: [
      "distanceMeters",
      "durationMillis",
      "legs",
      "path",
      "localizedValues",
      "travelAdvisory",
      "warnings",
      "viewport"
    ]
  });
  const route = result.routes?.[0];
  if (!route?.legs?.length) throw new Error("Google Maps returned no driving legs for this route.");
  const legs = route.legs as Array<any>;
  const totalMeters = Number(route.distanceMeters ?? legs.reduce((total, leg) => total + Number(leg.distanceMeters ?? 0), 0));
  const totalMillis = Number(route.durationMillis ?? legs.reduce((total, leg) => total + Number(leg.durationMillis ?? leg.staticDurationMillis ?? 0), 0));
  const path = routePathPoints(route);
  const legSummaries = legs.map((leg, index) => ({
    leg: index + 1,
    origin: addresses[index],
    destination: addresses[index + 1],
    distance_km: Number((Number(leg.distanceMeters ?? 0) / 1000).toFixed(2)),
    duration_hours: Number((Number(leg.durationMillis ?? leg.staticDurationMillis ?? 0) / 3600000).toFixed(2)),
    status: "OK"
  }));
  const stopSummaries = addresses.map((address, index) => {
    const sourceLeg = index === 0 ? legs[0] : legs[index - 1];
    const location = index === 0 ? sourceLeg?.startLocation?.latLng : sourceLeg?.endLocation?.latLng;
    const geocodedWaypoint = googleRoutesGeocodedWaypoint(result.geocodingResults, index, addresses.length);
    return {
      stop_order: index + 1,
      address,
      formatted_address: geocodedWaypoint?.formattedAddress ?? address,
      place_id: geocodedWaypoint?.placeId ?? null,
      latitude: coordinateValue(location?.lat ?? location?.latitude),
      longitude: coordinateValue(location?.lng ?? location?.longitude)
    };
  });

  return {
    distanceKm: Number((totalMeters / 1000).toFixed(2)),
    durationHours: Number((totalMillis / 3600000).toFixed(2)),
    googleMapsUrl: googleMapsDirectionsUrl(addresses),
    providerResponse: {
      provider: "google_maps",
      method: "maps_javascript_routes",
      leg_count: legSummaries.length,
      legs: legSummaries,
      stops: stopSummaries,
      path,
      overview_polyline: encodePolyline(path),
      warnings: route.warnings ?? [],
      toll_status: route.travelAdvisory?.tollInfo ? "available" : "unavailable",
      toll_info: route.travelAdvisory?.tollInfo ?? null,
      toll_note: "Routes library toll advisory is captured when Google returns toll info; configured toll fallback remains in pricing.",
      route_risk_status: "default_or_manual",
      calculated_at: new Date().toISOString()
    }
  };
}

function coordinateValue(value: unknown): number | null {
  if (typeof value === "function") return coordinateValue(value());
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : null;
}

function routePathPoints(route: any): Array<{ latitude: number; longitude: number }> {
  const path = Array.isArray(route.path) ? route.path : [];
  return path
    .map((point: any) => ({
      latitude: coordinateValue(point?.lat ?? point?.latitude),
      longitude: coordinateValue(point?.lng ?? point?.longitude)
    }))
    .filter((point: { latitude: number | null; longitude: number | null }) => point.latitude !== null && point.longitude !== null) as Array<{ latitude: number; longitude: number }>;
}

function googleRoutesGeocodedWaypoint(geocodingResults: any, index: number, stopCount: number): any {
  if (!geocodingResults) return null;
  if (index === 0) return geocodingResults.origin ?? null;
  if (index === stopCount - 1) return geocodingResults.destination ?? null;
  return (geocodingResults.intermediates ?? []).find((item: any) => Number(item.intermediateWaypointRequestIndex) === index - 1) ?? null;
}

function encodePolyline(points: Array<{ latitude: number; longitude: number }>): string | null {
  if (!points.length) return null;
  let previousLatitude = 0;
  let previousLongitude = 0;
  const encodeValue = (value: number): string => {
    let shifted = value < 0 ? ~(value << 1) : value << 1;
    let output = "";
    while (shifted >= 0x20) {
      output += String.fromCharCode((0x20 | (shifted & 0x1f)) + 63);
      shifted >>= 5;
    }
    return output + String.fromCharCode(shifted + 63);
  };
  return points.map((point) => {
    const latitude = Math.round(point.latitude * 1e5);
    const longitude = Math.round(point.longitude * 1e5);
    const encoded = encodeValue(latitude - previousLatitude) + encodeValue(longitude - previousLongitude);
    previousLatitude = latitude;
    previousLongitude = longitude;
    return encoded;
  }).join("");
}

function dynamicValue(source: Record<string, unknown> | undefined, key: string, fallback = "Not calculated"): string {
  if (!source || source[key] === null || source[key] === undefined || source[key] === "") return fallback;
  return String(source[key]);
}

function renderPricingSummaryCard(request: QuoteRequest): string {
  const calculation = request.pricingCalculation;
  const breakdowns = request.pricingBreakdowns ?? [];
  const adjustments = request.pricingAdjustments ?? [];
  const componentOverrides = request.pricingComponentOverrides ?? [];

  if (!calculation) {
    return `
      <section class="pricing-summary-card">
        <div class="card-heading"><h2>Pricing Summary</h2><span>Configure rules first</span></div>
        <p class="muted">No pricing calculation is available yet. Configure pricing settings, then regenerate after Vehicle Intelligence runs.</p>
      </section>
    `;
  }

  const dynamicInputs = calculation.dynamic_inputs ?? {};
  const dynamicOutputs = calculation.dynamic_outputs ?? {};
  const auditEvents = calculation.pricing_calculation_audit_events ?? [];
  const meaningfulBreakdowns = breakdowns.filter((line) => Math.abs(Number(line.amount ?? 0)) > 0.005);
  const dynamicLines = meaningfulBreakdowns.filter((line) =>
    ["fuel_surcharge", "seasonal_multiplier", "tolls", "route_risk", "profit"].includes(line.line_key)
  );
  const operatingCost = meaningfulBreakdowns
    .filter((line) => ["fuel", "driver", "maintenance", "tyres", "insurance", "depreciation"].includes(line.line_key))
    .reduce((total, line) => total + Number(line.amount ?? 0), 0);
  const adjustmentsTotal = meaningfulBreakdowns
    .filter((line) => !["fuel", "driver", "maintenance", "tyres", "insurance", "depreciation", "profit", "vat"].includes(line.line_key))
    .reduce((total, line) => total + Number(line.amount ?? 0), 0);

  return `
    <section class="pricing-summary-card">
      <div class="card-heading"><h2>Pricing Summary</h2><span>${escapeHtml(calculation.rule_version)}${calculation.manager_review_required ? " - manager review required" : ""}</span></div>
      <div class="price-hero">
        <span>Recommended selling price</span>
        <strong>${money(calculation.recommended_selling_price, calculation.currency)}</strong>
        <small>Includes ${money(calculation.vat_amount, calculation.currency)} VAT</small>
      </div>
      <div class="grid three">
        <p><strong>Route used</strong><span>${formatDistanceKm(calculation.estimated_distance_km)} / ${formatDurationHours(calculation.estimated_duration_hours)}</span></p>
        <p><strong>Estimated operating cost</strong><span>${money(operatingCost, calculation.currency)}</span></p>
        <p><strong>Adjustments</strong><span>${money(adjustmentsTotal, calculation.currency)}</span></p>
        <p><strong>Profit / margin</strong><span>${money(calculation.profit_amount, calculation.currency)}</span></p>
        <p><strong>VAT</strong><span>${money(calculation.vat_amount, calculation.currency)}</span></p>
        <p><strong>Diesel price</strong><span>${money(calculation.fuel_price_per_litre ?? Number(dynamicInputs.diesel_price_per_litre ?? 0), calculation.currency)} / L</span></p>
        <p><strong>Seasonal multiplier</strong><span>${formatNumber(Number(calculation.seasonal_multiplier ?? dynamicInputs.seasonal_multiplier ?? 1), 2)}x</span></p>
        <p><strong>Margin profile</strong><span>${escapeHtml(calculation.margin_profile_key ?? dynamicValue(dynamicInputs, "margin_profile", "target"))}</span></p>
      </div>
      <details class="detail-disclosure">
        <summary>Detailed pricing lines</summary>
        <div class="table-wrap">
        <table>
          <thead><tr><th>Line</th><th>Quantity</th><th>Rate</th><th>Amount</th></tr></thead>
          <tbody>
            ${meaningfulBreakdowns.map((line) => `<tr><td>${escapeHtml(line.line_label)}<br><small>${escapeHtml(line.explanation ?? "")}</small></td><td>${formatNumber(line.quantity, 2)}</td><td>${money(line.unit_rate, calculation.currency)}</td><td>${money(line.amount, calculation.currency)}</td></tr>`).join("")}
          </tbody>
        </table>
        </div>
      </details>
      <div class="summary-block">
        <h3>Calculation drivers</h3>
        <div class="grid three">
          <p><strong>Fuel surcharge</strong><span>${money(calculation.fuel_surcharge_amount ?? Number(dynamicOutputs.fuel_surcharge_amount ?? 0), calculation.currency)}</span></p>
          <p><strong>Toll framework</strong><span>${money(calculation.toll_amount ?? Number(dynamicOutputs.toll_amount ?? 0), calculation.currency)}</span></p>
          <p><strong>Route risk</strong><span>${money(calculation.route_risk_amount ?? Number(dynamicOutputs.route_risk_amount ?? 0), calculation.currency)}</span></p>
          <p><strong>Seasonal impact</strong><span>${money(calculation.seasonal_amount ?? Number(dynamicOutputs.seasonal_amount ?? 0), calculation.currency)}</span></p>
          <p><strong>Company overhead</strong><span>${money(Number(dynamicOutputs.company_overhead_amount ?? 0), calculation.currency)}</span></p>
          <p><strong>Margin %</strong><span>${calculation.margin_percent ?? dynamicValue(dynamicInputs, "margin_percent", "Profile default")}</span></p>
        </div>
        <p class="muted">${escapeHtml(calculation.calculation_notes ?? "Dynamic pricing uses route distance, vehicle operating cost profile, diesel inputs, seasonal multiplier, route risk, toll framework, company overhead, margin profile, and VAT.")}</p>
        ${dynamicLines.length ? `<div class="flag-row">${dynamicLines.map((line) => `<span class="flag info">${escapeHtml(line.line_label)}: ${money(line.amount, calculation.currency)}</span>`).join("")}</div>` : ""}
        ${auditEvents.length ? `<small>${auditEvents.length} calculation audit event(s) recorded.</small>` : `<small>Calculation audit/history foundation is enabled for new dynamic calculations.</small>`}
      </div>
      <div class="summary-block">
        <h3>Component override foundation</h3>
        <div class="grid three">
          <label>Pricing line
            <select name="componentOverrideLine">
              <option value="">Select a line</option>
              ${breakdowns.map((line) => `<option value="${escapeHtml(line.line_key)}">${escapeHtml(line.line_label)}</option>`).join("")}
            </select>
          </label>
          <label>Override amount<input name="componentOverrideAmount" type="number" min="0" step="0.01" placeholder="0.00" /></label>
          <label>Reason<input name="componentOverrideReason" placeholder="Required for component override" /></label>
        </div>
        <small>${componentOverrides.length} component override(s) recorded. Component overrides are internal manager audit records; final selling price still uses the manager override below before approval.</small>
      </div>
      <div class="summary-block">
        <h3>Manager final price override</h3>
        <div class="grid two">
          <label>Override final selling price<input name="overrideSellingPrice" type="number" min="0" step="0.01" value="${calculation.recommended_selling_price}" /></label>
          <label>Override reason<textarea name="overrideReason" placeholder="Required when overriding price"></textarea></label>
        </div>
        <small>${adjustments.length} adjustment(s) recorded.</small>
      </div>
    </section>
  `;
}

function valueText(value: unknown, fallback = "Not supplied"): string {
  if (value === null || value === undefined || value === "") return fallback;
  return String(value);
}

function formatKg(value: number): string {
  if (!Number.isFinite(value)) return "0";
  return formatNumber(value, 2);
}

type CargoWeightLike = {
  quantity?: unknown;
  weight_kg?: unknown;
  notes?: unknown;
};

function noteTotalShipmentWeight(item: CargoWeightLike): number | null {
  const match = String(item.notes ?? "").match(/Total shipment weight:\s*([0-9]+(?:\.[0-9]+)?)\s*kg/i);
  if (!match) return null;
  const value = Number(match[1]);
  return Number.isFinite(value) && value > 0 ? value : null;
}

function itemTotalWeightKg(item: CargoWeightLike): number {
  return noteTotalShipmentWeight(item) ?? (Number(item.quantity) || 1) * (Number(item.weight_kg) || 0);
}

function cargoWeightLabel(item: CargoWeightLike): string {
  const totalWeight = noteTotalShipmentWeight(item);
  if (totalWeight !== null) return `total ${formatKg(totalWeight)}kg`;
  return `${formatKg(Number(item.weight_kg) || 0)}kg each`;
}

function acceptedLoadPrice(request: QuoteRequest): number | null {
  const latestDocument = request.quoteDocuments?.[0];
  return latestDocument?.final_selling_price ?? request.pricingCalculation?.recommended_selling_price ?? request.quotePrice ?? null;
}

function renderAcceptedLoadCard(request: QuoteRequest): string {
  const vehicle = request.vehicleRecommendation;
  const vehicleLabel = vehicle
    ? `${vehicle.recommended_vehicle_type} / ${vehicle.recommended_trailer_type}`
    : `${request.suggestedVehicle} / ${request.suggestedTrailer}`;
  const load = request.items?.length
    ? request.items.map((item) => `${item.description || item.cargo_category} (${item.quantity} item(s), ${cargoWeightLabel(item)})`).join("; ")
    : `${request.loadDescription || request.cargoType} (${request.quantity} x ${request.weight}kg)`;
  const acceptedAt = request.transportJob?.created_at ?? request.createdAt;

  return `
    <article class="quote-row accepted-load-row">
      <div class="accepted-load-main">
        <strong>${escapeHtml(request.transportJob?.job_number ?? `LOAD-${request.publicReference ?? request.id.slice(0, 8)}`)}</strong>
        <span>${escapeHtml(request.companyName)} - ${escapeHtml(request.contactPerson)}</span>
        <small>${escapeHtml(quoteShortRoute(request))}</small>
      </div>
      <div class="accepted-load-register">
        <span><strong>Collection</strong>${escapeHtml(request.collectionDate || "Pending")}</span>
        <span><strong>Load</strong>${escapeHtml(load || "Pending")}</span>
        <span><strong>Vehicle</strong>${escapeHtml(vehicleLabel || "To be confirmed")}</span>
        <span><strong>Accepted price</strong>${money(acceptedLoadPrice(request))}</span>
        <span><strong>Accepted date</strong>${escapeHtml(formatDateTime(acceptedAt))}</span>
      </div>
      <div class="quote-card-actions">
        <span class="badge">Accepted load</span>
        <small><strong>Status</strong> ${escapeHtml(statusLabels[request.status] ?? request.status)}</small>
        <a class="button small" href="./quote-review.html?id=${request.id}">Open Quote</a>
      </div>
    </article>
  `;
}

function jsonForTextarea(value: unknown): string {
  return escapeHtml(JSON.stringify(value ?? {}, null, 2));
}

function renderSystemSetting(setting: SystemSettingRecord, index: number, canUpdate: boolean): string {
  return `
    <div class="summary-block">
      <h3>${escapeHtml(setting.display_name)}</h3>
      <p><strong>Key</strong><span>${escapeHtml(setting.setting_key)}</span></p>
      <p><strong>Category</strong><span>${escapeHtml(setting.setting_category)}</span></p>
      <p><strong>Access</strong><span>${setting.is_restricted ? "Owner/admin only" : "Safe internal read"}</span></p>
      <input type="hidden" name="system_key_${index}" value="${escapeHtml(setting.setting_key)}" />
      <input type="hidden" name="system_category_${index}" value="${escapeHtml(setting.setting_category)}" />
      <input type="hidden" name="system_display_${index}" value="${escapeHtml(setting.display_name)}" />
      <input type="hidden" name="system_restricted_${index}" value="${setting.is_restricted ? "true" : "false"}" />
      <label>Setting JSON<textarea name="system_value_${index}" rows="6" ${canUpdate ? "" : "disabled"}>${jsonForTextarea(setting.setting_value)}</textarea></label>
    </div>
  `;
}

function renderEmailTemplate(template: EmailTemplatePlaceholderRecord, index: number, canUpdate: boolean): string {
  return `
    <div class="summary-block">
      <h3>${escapeHtml(template.template_name)}</h3>
      <p><strong>Key</strong><span>${escapeHtml(template.template_key)}</span></p>
      <input type="hidden" name="template_key_${index}" value="${escapeHtml(template.template_key)}" />
      <label>Name<input name="template_name_${index}" value="${escapeHtml(template.template_name)}" ${canUpdate ? "" : "disabled"} /></label>
      <label>Subject<input name="template_subject_${index}" value="${escapeHtml(template.subject_placeholder)}" ${canUpdate ? "" : "disabled"} /></label>
      <label>Body placeholder<textarea name="template_body_${index}" rows="5" ${canUpdate ? "" : "disabled"}>${escapeHtml(template.body_placeholder)}</textarea></label>
      <label>Variables JSON<textarea name="template_variables_${index}" rows="4" ${canUpdate ? "" : "disabled"}>${jsonForTextarea(template.available_variables)}</textarea></label>
      <label class="checkbox"><input name="template_active_${index}" type="checkbox" ${template.is_active ? "checked" : ""} ${canUpdate ? "" : "disabled"} /> Active</label>
    </div>
  `;
}

function renderNumberingSequence(sequence: NumberingSequenceSettingRecord, index: number, canUpdate: boolean): string {
  return `
    <div class="summary-block">
      <h3>${escapeHtml(sequence.display_name)}</h3>
      <input type="hidden" name="sequence_key_${index}" value="${escapeHtml(sequence.sequence_key)}" />
      <label>Display name<input name="sequence_display_${index}" value="${escapeHtml(sequence.display_name)}" ${canUpdate ? "" : "disabled"} /></label>
      <label>Prefix<input name="sequence_prefix_${index}" value="${escapeHtml(sequence.prefix)}" ${canUpdate ? "" : "disabled"} /></label>
      <label>Next number<input name="sequence_next_${index}" type="number" min="1" value="${sequence.next_number}" ${canUpdate ? "" : "disabled"} /></label>
      <label>Padding<input name="sequence_padding_${index}" type="number" min="1" max="12" value="${sequence.padding}" ${canUpdate ? "" : "disabled"} /></label>
      <label>Suffix<input name="sequence_suffix_${index}" value="${escapeHtml(sequence.suffix ?? "")}" ${canUpdate ? "" : "disabled"} /></label>
    </div>
  `;
}

function renderAdminSettings(settings: InternalSettingsPayload): string {
  const branding = settings.company_branding ?? {};
  const value = (key: string): string => String(branding[key] ?? "");
  const canUpdate = Boolean(settings.can_update);
  return `
    <form id="adminSettingsForm" class="stack">
      <div class="notice ${canUpdate ? "" : "muted"}">
        <strong>${canUpdate ? "Owner/admin edit access active" : "Read-only internal settings view"}</strong>
        <span>${canUpdate ? "Changes are saved through audited owner controls." : "Managers and viewers can read safe settings only. Restricted updates require owner access."}</span>
      </div>

      <section>
        <div class="card-heading"><h2>Company branding</h2><span>Customer-facing settings</span></div>
        <div class="grid three">
          <label>Company name<input name="company_name" value="${escapeHtml(value("company_name"))}" ${canUpdate ? "" : "disabled"} /></label>
          <label>Trading name<input name="trading_name" value="${escapeHtml(value("trading_name"))}" ${canUpdate ? "" : "disabled"} /></label>
          <label>Website URL<input name="website_url" value="${escapeHtml(value("website_url"))}" ${canUpdate ? "" : "disabled"} /></label>
          <label>Logo URL<input name="logo_url" value="${escapeHtml(value("logo_url"))}" ${canUpdate ? "" : "disabled"} /></label>
          <label>Primary color<input name="primary_color" value="${escapeHtml(value("primary_color"))}" ${canUpdate ? "" : "disabled"} /></label>
          <label>Accent color<input name="accent_color" value="${escapeHtml(value("accent_color"))}" ${canUpdate ? "" : "disabled"} /></label>
          <label>Contact email<input name="contact_email" value="${escapeHtml(value("contact_email"))}" ${canUpdate ? "" : "disabled"} /></label>
          <label>Contact phone<input name="contact_phone" value="${escapeHtml(value("contact_phone"))}" ${canUpdate ? "" : "disabled"} /></label>
          <label>Address<input name="address" value="${escapeHtml(value("address"))}" ${canUpdate ? "" : "disabled"} /></label>
        </div>
        <label>Quote footer<textarea name="quote_footer" rows="4" ${canUpdate ? "" : "disabled"}>${escapeHtml(value("quote_footer"))}</textarea></label>
      </section>

      <section>
        <div class="card-heading"><h2>Numbering sequences</h2><span>RFQ, quote, accepted load</span></div>
        <div class="grid two">
          ${settings.numbering_sequences.map((sequence, index) => renderNumberingSequence(sequence, index, canUpdate)).join("")}
        </div>
      </section>

      <section>
        <div class="card-heading"><h2>Email templates</h2><span>Provider-backed delivery</span></div>
        <div class="grid two">
          ${settings.email_templates.map((template, index) => renderEmailTemplate(template, index, canUpdate)).join("")}
        </div>
      </section>

      <section>
        <div class="card-heading"><h2>Integrations</h2><span>Operational provider status</span></div>
        <div class="notice integration-notice">
          <strong>Integration status</strong>
          <span>Google Maps: ${googleMapsApiKey ? "configured" : "not configured"}. PDF, email, signed downloads, and file uploads use the production-integrations Edge Function. Email delivery requires server-side provider secrets; missing secrets are recorded as failed email attempts.</span>
        </div>
      </section>

      <section>
        <div class="card-heading"><h2>Operational settings</h2><span>Advanced configuration</span></div>
        <div class="grid two">
          ${settings.system_settings.map((setting, index) => renderSystemSetting(setting, index, canUpdate)).join("")}
        </div>
      </section>

      <section>
        <div class="card-heading"><h2>Recent audit log</h2><span>Owner view</span></div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Time</th><th>Action</th><th>Entity</th><th>Actor</th></tr></thead>
            <tbody>
              ${settings.recent_audit_logs.length > 0 ? settings.recent_audit_logs.map((log) => `
                <tr>
                  <td>${escapeHtml(log.created_at)}</td>
                  <td>${escapeHtml(log.action)}</td>
                  <td>${escapeHtml(log.entity_type)}</td>
                  <td>${escapeHtml(log.actor_role ?? "internal")}</td>
                </tr>
              `).join("") : `<tr><td colspan="4">No audit events visible for this user.</td></tr>`}
            </tbody>
          </table>
        </div>
      </section>

      ${canUpdate ? `<button class="primary" type="submit">Save admin settings</button>` : ""}
      <output id="adminSettingsOutput"></output>
    </form>
  `;
}

function renderCustomerQuoteDocument(document: PublicQuoteDocumentRecord): string {
  const payload = document.customer_payload ?? {};
  const brand = payload.brand ?? {};
  const pricing = payload.pricing ?? {};
  const route = payload.route_estimate ?? {};
  const transport = payload.transport ?? {};
  const customer = payload.customer ?? {};
  const stops = Array.isArray(payload.stops) ? payload.stops : [];
  const cargoItems = Array.isArray(payload.cargo_items) ? payload.cargo_items : [];
  const terms = Array.isArray(brand.terms) ? brand.terms : [];

  return `
    <article class="customer-quote">
      <header class="quote-document-header">
        <div class="quote-document-brand">
          <img class="quote-document-logo" src="./time-trucking-logo.png" alt="Time Trucking - Total Logistic Solutions" />
          <p class="eyebrow">${escapeHtml(brand.brand_name ?? "Time Trucking")}</p>
          <h1>Transport Quote</h1>
          <p class="muted">${escapeHtml(brand.brand_line ?? "Professional transport solutions")}</p>
        </div>
        <div class="quote-number">
          <strong>${escapeHtml(document.quote_number)}</strong>
          <span>Version ${document.version_number}</span>
        </div>
      </header>
      <section class="grid three">
        <p><strong>Quote date</strong><span>${escapeHtml(formatDateOnly(document.quote_date))}</span></p>
        <p><strong>Valid until</strong><span>${escapeHtml(formatDateOnly(document.validity_date))}</span></p>
        <p><strong>Status</strong><span>${statusLabels[document.status]}</span></p>
      </section>
      <section class="summary-block">
        <h3>Customer</h3>
        <p><strong>${escapeHtml(valueText(customer.company_name))}</strong></p>
        <p>${escapeHtml(valueText(customer.contact_person))} - ${escapeHtml(valueText(customer.email))}</p>
        <p>${escapeHtml(valueText(customer.phone))}</p>
      </section>
      <section class="summary-block">
        <h3>Route</h3>
        <p><strong>Origin</strong><span>${escapeHtml(valueText(route.origin_address))}</span></p>
        <p><strong>Destination</strong><span>${escapeHtml(valueText(route.destination_address))}</span></p>
        <p><strong>Estimate</strong><span>${formatDistanceKm(Number(route.total_distance_km ?? 0))} / ${formatDurationHours(Number(route.total_duration_hours ?? 0))}</span></p>
      </section>
      <section class="summary-block">
        <h3>Stops</h3>
        ${stops.length ? stops.map((stop) => `<p>${escapeHtml(valueText(stop.stop_order))}. <strong>${escapeHtml(valueText(stop.stop_type, "stop"))}</strong> - ${escapeHtml(valueText(stop.address))}</p>`).join("") : `<p class="muted">No stops captured.</p>`}
      </section>
      <section class="summary-block">
        <h3>Cargo</h3>
        ${cargoItems.length ? cargoItems.map((item) => `<p><strong>${escapeHtml(valueText(item.description, "Cargo item"))}</strong> - ${escapeHtml(valueText(item.quantity, "1"))} item(s), ${escapeHtml(cargoWeightLabel(item))}</p>`).join("") : `<p class="muted">No cargo items captured.</p>`}
      </section>
      <section class="grid three">
        <p><strong>Vehicle</strong><span>${escapeHtml(valueText(transport.recommended_vehicle_type, "To be confirmed"))}</span></p>
        <p><strong>Trailer</strong><span>${escapeHtml(valueText(transport.recommended_trailer_type, "To be confirmed"))}</span></p>
        <p><strong>Trucks</strong><span>${escapeHtml(valueText(transport.number_of_trucks, "1"))}</span></p>
      </section>
      <section class="quote-total">
        <p><strong>Final selling price</strong><span>${money(pricing.final_selling_price ?? document.final_selling_price, pricing.currency ?? document.currency)}</span></p>
        <p><strong>VAT included</strong><span>${money(pricing.vat_amount ?? document.vat_amount, pricing.currency ?? document.currency)}</span></p>
      </section>
      <section class="summary-block">
        <h3>Terms and conditions</h3>
        ${terms.length ? terms.map((term) => `<p>${escapeHtml(term)}</p>`).join("") : `<p>Quote is subject to final confirmation and Time Trucking standard transport terms.</p>`}
      </section>
      <div class="button-row">
        <button class="primary" data-quote-decision="client_accepted">Accept quote</button>
        <button data-quote-decision="client_declined">Decline quote</button>
        <button type="button" id="revisionRequestButton">Request revision</button>
        <button type="button" id="customerDownloadPdfButton">Download PDF</button>
      </div>
      <label id="revisionMessageLabel" hidden>Revision notes
        <textarea id="revisionMessage" placeholder="Tell Time Trucking what needs to change"></textarea>
      </label>
    </article>
  `;
}

function renderCustomerPortal(record: CustomerPortalRecord): string {
  const documents = Array.isArray(record.quote_documents) ? record.quote_documents : [];
  const accepted = record.quote_status === "client_accepted" || record.quote_status === "converted_to_load";
  const declined = record.quote_status === "client_declined";
  return `
    <div class="detail-grid">
      <div class="card-heading">
        <h2>${escapeHtml(record.company_name)}</h2>
        <span>${escapeHtml(record.public_reference ?? record.quote_request_id)}</span>
      </div>
      <div class="grid three">
        <p><strong>Quote status</strong><span>${escapeHtml(statusLabels[record.quote_status] ?? record.quote_status)}</span></p>
        <p><strong>Accepted</strong><span>${escapeHtml(record.accepted_at ?? "Not accepted")}</span></p>
        <p><strong>Declined</strong><span>${escapeHtml(record.declined_at ?? "Not declined")}</span></p>
      </div>
      <div class="summary-block">
        <h3>Quote documents</h3>
        ${documents.length ? documents.map((document) => `<p><strong>${escapeHtml(valueText(document.quote_number, "Quote document"))}</strong><span>Version ${escapeHtml(valueText(document.version_number, "1"))} - ${escapeHtml(valueText(document.quote_date, "Date pending"))}</span></p>`).join("") : `<p class="muted">No quote documents are available yet.</p>`}
      </div>
      <div class="summary-block">
        <h3>Customer response</h3>
        <p>${accepted ? "Quote accepted. Time Trucking has your approved quote and order reference." : declined ? "Quote declined. Time Trucking will review the response if follow-up is needed." : "Quote response is still pending."}</p>
      </div>
    </div>
  `;
}

function quoteDocumentToPublic(document: QuoteDocumentRecord): PublicQuoteDocumentRecord {
  return {
    quote_document_id: document.id,
    quote_request_id: document.quote_request_id,
    quote_number: document.quote_number,
    public_reference: document.public_reference,
    quote_date: document.quote_date,
    validity_date: document.validity_date,
    version_number: document.version_number,
    status: "sent_to_client",
    final_selling_price: document.final_selling_price,
    vat_amount: document.vat_amount,
    currency: document.currency,
    accept_link: document.accept_link,
    decline_link: document.decline_link,
    pdf_placeholder_url: document.pdf_placeholder_url,
    pdf_url: document.pdf_url ?? null,
    generated_at: document.generated_at ?? null,
    customer_payload: document.customer_payload
  };
}

function renderPrintableQuoteHtml(document: PublicQuoteDocumentRecord): string {
  const safeBody = renderCustomerQuoteDocument(document)
    .replace(/<button[\s\S]*?<\/button>/g, "")
    .replace(/<label id="revisionMessageLabel"[\s\S]*?<\/label>/g, "");
  return `<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <title>${escapeHtml(document.quote_number)} - Time Trucking Quote</title>
    <style>
      body { margin: 0; color: #18212f; font-family: Arial, sans-serif; background: white; }
      main { max-width: 920px; margin: 0 auto; padding: 32px; }
      h1, h2, h3, p { margin-top: 0; }
      .customer-quote, .grid, .summary-block, .quote-total { display: grid; gap: 12px; }
      .quote-document-header { display: grid; grid-template-columns: 1fr auto; gap: 18px; border-bottom: 2px solid #17202c; padding-bottom: 18px; }
      .eyebrow { color: #0f766e; font-size: 12px; font-weight: 800; text-transform: uppercase; }
      .muted, span { color: #657184; }
      .grid.three { grid-template-columns: repeat(3, 1fr); }
      .summary-block, .quote-total, .quote-number { border: 1px solid #d9e1ea; border-radius: 8px; padding: 14px; }
      .quote-total { border-color: #0f766e; background: #ecfffb; }
      .quote-total span { color: #18212f; font-size: 24px; font-weight: 800; }
      @media print { main { padding: 18mm; } .button-row { display: none; } }
    </style>
  </head>
  <body><main>${safeBody}</main></body>
</html>`;
}

function openPrintableQuote(document: PublicQuoteDocumentRecord): void {
  const printable = window.open("", "_blank", "noopener,noreferrer");
  if (!printable) return;
  printable.document.open();
  printable.document.write(renderPrintableQuoteHtml(document));
  printable.document.close();
  printable.focus();
  setTimeout(() => printable.print(), 250);
}

function formValue(form: FormData, key: string): string {
  const value = form.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function numberValue(form: FormData, key: string): number {
  const value = Number(formValue(form, key));
  return Number.isFinite(value) ? value : 0;
}

function updateStatus(id: string, status: QuoteStatus): void {
  const requests = readRequests();
  const request = requests.find((item) => item.id === id);
  if (!request) return;
  request.status = status;
  writeRequests(requests);
}

function dashboardGreeting(date = new Date()): string {
  const hour = date.getHours();
  if (hour < 12) return "Good morning";
  if (hour < 17) return "Good afternoon";
  return "Good evening";
}

function dashboardIcon(label: string): string {
  const icons: Record<string, string> = {
    rfq: "M7 3h8l4 4v14H7z M15 3v5h5 M10 12h7 M10 16h7",
    review: "M4 5h16v12H7l-3 3z M8 9h8 M8 13h5",
    approved: "M20 7 10 17l-5-5",
    sent: "M3 11l18-8-6 18-4-7z",
    accepted: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M8 12l3 3 5-6",
    completed: "M5 12l4 4L19 6",
    money: "M12 3v18 M17 7.5c0-2-2-3-5-3s-5 1-5 3 2 3 5 3 5 1 5 3-2 3-5 3-5-1-5-3",
    bell: "M18 16v-5a6 6 0 1 0-12 0v5l-2 2h16z M10 20h4"
  };
  return `<svg class="dashboard-icon-svg" viewBox="0 0 24 24" aria-hidden="true"><path d="${icons[label] ?? icons.rfq}"></path></svg>`;
}

function renderMetricCard(label: string, value: string | number, icon: string, helper: string, href?: string): string {
  const tag = href ? "a" : "div";
  const target = href ? ` href="${escapeHtml(href)}"` : "";
  return `
    <${tag} class="dashboard-metric-card"${target}>
      <span class="stat-icon">${dashboardIcon(icon)}</span>
      <strong>${escapeHtml(String(value))}</strong>
      <span>${escapeHtml(label)}</span>
      <small>${escapeHtml(helper)}</small>
    </${tag}>
  `;
}

function skeletonCards(count = 4): string {
  return Array.from({ length: count }, () => `
    <article class="skeleton-card" aria-hidden="true">
      <span></span><span></span><span></span>
    </article>
  `).join("");
}

function formatDateTime(value: string | null | undefined): string {
  if (!value) return "Date pending";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("en-ZA", {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit"
  }).format(date);
}

function formatDateOnly(value: string | null | undefined): string {
  if (!value) return "Date pending";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("en-ZA", {
    day: "2-digit",
    month: "short",
    year: "numeric"
  }).format(date);
}

function renderShellActiveNav(): void {
  const page = document.body.dataset.page;
  document.querySelectorAll<HTMLAnchorElement>("[data-nav]").forEach((link) => {
    link.classList.toggle("active", link.dataset.nav === page);
  });
  const header = document.querySelector<HTMLElement>(".header");
  if (!header || !isInternalPage() || !currentInternalUser || header.querySelector(".session-panel")) return;
  const panel = document.createElement("div");
  panel.className = "session-panel";
  panel.innerHTML = `
    <span>Signed in as</span>
    <strong>${escapeHtml(userDisplayName(currentInternalUser))}</strong>
    <small>${escapeHtml(currentInternalUser.role)}</small>
    <button class="button small" type="button" id="signOutButton">Sign out</button>
  `;
  header.appendChild(panel);
  panel.querySelector<HTMLButtonElement>("#signOutButton")?.addEventListener("click", async () => {
    try {
      if (isSupabaseConfigured) await signOutInternalUser();
    } finally {
      window.location.href = "./login.html";
    }
  });
}

async function initLogin(): Promise<void> {
  if (!isLoginPage()) return;
  const form = document.querySelector<HTMLFormElement>("#loginForm");
  const output = document.querySelector<HTMLElement>("#loginOutput");
  const passwordInput = document.querySelector<HTMLInputElement>("#loginPassword");
  const showPasswordToggle = document.querySelector<HTMLInputElement>("#showPasswordToggle");
  if (!form || !output) return;

  showPasswordToggle?.addEventListener("change", () => {
    if (passwordInput) passwordInput.type = showPasswordToggle.checked ? "text" : "password";
  });

  if (!isSupabaseConfigured) {
    output.innerHTML = `<strong>Backend not configured.</strong><span>Add the Time Trucking app connection before logging in.</span>`;
    return;
  }

  try {
    if (await hasSupabaseSession()) {
      const user = await loadCurrentInternalUser();
      if (user?.user_status === "active") {
        window.location.href = "./index.html";
        return;
      }
    }
  } catch {
    await signOutInternalUser();
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(form);
    const email = formValue(data, "email");
    const password = formValue(data, "password");
    const redirect = new URLSearchParams(window.location.search).get("redirect") || "index.html";
    output.innerHTML = `<strong>Signing in...</strong><span>Checking Time Trucking internal access.</span>`;

    try {
      await signInInternalUser(email, password);
      const internalUser = await loadCurrentInternalUser();
      if (!internalUser) {
        output.innerHTML = `<strong>Access pending.</strong><span>Your login is valid, but no Time Trucking internal user record exists yet. Ask an owner to add your user.</span>`;
        return;
      }
      if (internalUser.user_status !== "active") {
        output.innerHTML = `<strong>Access revoked.</strong><span>Your Time Trucking internal user account is not active.</span>`;
        return;
      }
      window.location.href = redirect;
    } catch (error) {
      output.innerHTML = `<strong>Login failed.</strong><span>${escapeHtml(friendlyError(error, "Invalid email or password. Please try again."))}</span>`;
    }
  });
}

async function initDashboard(): Promise<void> {
  const list = document.querySelector<HTMLElement>("#rfqList");
  const counts = document.querySelector<HTMLElement>("#dashboardCounts");
  const actions = document.querySelector<HTMLElement>("#managerActions");
  const welcome = document.querySelector<HTMLElement>("#managerWelcome");
  const greeting = document.querySelector<HTMLElement>("#managerGreeting");
  const statusArea = document.querySelector<HTMLElement>("#managerStatusArea");
  const trendPanel = document.querySelector<HTMLElement>("#quoteTrendPanel");
  const recentActivity = document.querySelector<HTMLElement>("#recentActivity");
  if (!list || !counts || !actions) return;

  const user = currentInternalUser;
  if (!user) {
    list.innerHTML = `<p class="muted">Manager Portal requires an active Time Trucking internal user.</p>`;
    return;
  }

  const now = new Date();
  if (greeting) greeting.textContent = `${dashboardGreeting(now)}, ${userDisplayName(user).split(" ")[0]}`;
  if (welcome) {
    welcome.textContent = `Live Time Trucking quote workflow for ${new Intl.DateTimeFormat("en-ZA", { weekday: "long", day: "2-digit", month: "long", year: "numeric" }).format(now)}.`;
  }
  if (statusArea) {
    statusArea.innerHTML = `
      <div class="manager-date">${new Intl.DateTimeFormat("en-ZA", { day: "2-digit", month: "short", year: "numeric" }).format(now)}</div>
      <span class="role-badge">${escapeHtml(user.role)}</span>
      <div class="notification-pill">${dashboardIcon("bell")} Loading alerts</div>
    `;
  }

  counts.innerHTML = skeletonCards(6);
  actions.innerHTML = "";
  list.innerHTML = skeletonCards(3);
  if (trendPanel) trendPanel.innerHTML = skeletonCards(1);
  if (recentActivity) recentActivity.innerHTML = skeletonCards(3);

  let requests: QuoteRequest[] = [];
  if (!isSupabaseConfigured) {
    counts.innerHTML = `<p class="muted">Connect Supabase to load live Manager Portal metrics.</p>`;
    list.innerHTML = `<p class="muted">Supabase is required for the production Manager Portal dashboard.</p>`;
    return;
  }

  try {
    const requestRecords = await loadAdminQuoteRequests();
    requests = requestRecords.map(requestFromRecord);
  } catch (error) {
    const message = friendlyError(error, "The Manager Portal could not load live Supabase data. Check your internal permissions and connection.");
    counts.innerHTML = `<p class="muted">Dashboard metrics unavailable: ${escapeHtml(message)}</p>`;
    actions.innerHTML = renderDashboardActions(user, { quoteRequestCount: 0, reviewCount: 0, sentCount: 0, declinedCount: 0, acceptedCount: 0 });
    list.innerHTML = `<p class="muted">RFQ queue unavailable: ${escapeHtml(message)}</p>`;
    if (trendPanel) trendPanel.innerHTML = `<p class="muted">Quote analytics unavailable: ${escapeHtml(message)}</p>`;
    if (recentActivity) recentActivity.innerHTML = `<p class="muted">Recent activity unavailable: ${escapeHtml(message)}</p>`;
    if (statusArea) {
      statusArea.innerHTML = `
        <div class="manager-date">${new Intl.DateTimeFormat("en-ZA", { day: "2-digit", month: "short", year: "numeric" }).format(now)}</div>
        <span class="role-badge">${escapeHtml(user.role)}</span>
        <div class="notification-pill warning">${dashboardIcon("bell")} Data load issue</div>
      `;
    }
    return;
  }

  const newRfqCount = requests.filter((request) => ["rfq_submitted", "client_submitted"].includes(request.status)).length;
  const reviewCount = requests.filter((request) => ["admin_review", "adjusted"].includes(request.status)).length;
  const approvedCount = requests.filter((request) => request.status === "approved").length;
  const sentCount = requests.filter((request) => request.status === "sent_to_client").length;
  const acceptedCount = requests.filter((request) => request.transportJob || ["client_accepted", "converted_to_load"].includes(request.status)).length;
  const declinedCount = requests.filter((request) => request.status === "client_declined").length;
  const generatedQuoteCount = requests.filter((request) => ["approved", "sent_to_client", "client_accepted", "client_declined", "converted_to_load"].includes(request.status)).length;
  const conversionBase = acceptedCount + declinedCount;
  const conversionRate = conversionBase ? Math.round((acceptedCount / conversionBase) * 100) : 0;
  const urgentCount = newRfqCount + reviewCount + declinedCount;

  counts.innerHTML = `
    ${renderMetricCard("New Requests", newRfqCount, "rfq", "Fresh customer submissions", "./quote-review.html?status=client_submitted")}
    ${renderMetricCard("Needs Review", reviewCount, "review", "Manager decision required", "./quote-review.html?status=admin_review")}
    ${renderMetricCard("Approved", approvedCount, "approved", "Ready to send", "./quote-review.html?status=approved")}
    ${renderMetricCard("Sent", sentCount, "sent", "Awaiting customer response", "./quote-review.html?status=sent_to_client")}
    ${renderMetricCard("Declined", declinedCount, "warning", "Review required", "./quote-review.html?status=client_declined")}
    ${renderMetricCard("Accepted Loads", acceptedCount, "accepted", `${conversionRate}% close rate`, "./accepted-loads.html")}
  `;
  if (statusArea) {
    statusArea.innerHTML = `
      <div class="manager-date">${new Intl.DateTimeFormat("en-ZA", { weekday: "short", day: "2-digit", month: "short", year: "numeric" }).format(now)}</div>
      <span class="role-badge">${escapeHtml(user.role)}</span>
      <div class="notification-pill ${urgentCount ? "warning" : ""}">${dashboardIcon("bell")} ${urgentCount ? `${urgentCount} items need attention` : "All queues steady"}</div>
    `;
  }

  actions.innerHTML = renderDashboardActions(user, {
    quoteRequestCount: newRfqCount,
    reviewCount,
    sentCount,
    declinedCount,
    acceptedCount
  });

  if (trendPanel) {
    trendPanel.innerHTML = renderQuoteTrendPanel({
      totalRfqs: requests.length,
      generatedQuoteCount,
      acceptedCount,
      declinedCount,
      conversionRate,
      totalQuotedValue: requests.reduce((total, request) => total + Number(request.quotePrice ?? 0), 0),
      acceptedValue: requests
        .filter((request) => request.transportJob || ["client_accepted", "converted_to_load"].includes(request.status))
        .reduce((total, request) => total + Number(request.quotePrice ?? 0), 0)
    });
  }

  if (recentActivity) {
    recentActivity.innerHTML = renderRecentActivity(requests);
  }

  list.innerHTML = requests.length
    ? requests.slice(0, 12).map((request) => `
      <article class="quote-row">
        <div>
          <strong>${escapeHtml(request.companyName)}</strong>
          <span>${escapeHtml(request.publicReference ?? request.id)} - ${escapeHtml(quoteShortRoute(request))}</span>
        </div>
        <div>
          <span class="badge">${statusLabels[request.status]}</span>
          <a class="button small" href="./quote-review.html?id=${request.id}">Review</a>
        </div>
      </article>
    `).join("")
    : `<p class="muted">No RFQs have been submitted yet. Create a secure RFQ link and send it to a customer to begin the live workflow.</p>`;
}

function renderQuoteTrendPanel(metrics: {
  totalRfqs: number;
  generatedQuoteCount: number;
  acceptedCount: number;
  declinedCount: number;
  conversionRate: number;
  totalQuotedValue: number;
  acceptedValue: number;
}): string {
  return `
    <div class="analytics-panel">
      <div class="analytics-meter">
        <strong>${metrics.conversionRate}%</strong>
        <span>Quote conversion</span>
      </div>
      <div class="analytics-list">
        <p><strong>Total RFQs</strong><span>${metrics.totalRfqs}</span></p>
        <p><strong>Quotes generated</strong><span>${metrics.generatedQuoteCount}</span></p>
        <p><strong>Accepted / declined</strong><span>${metrics.acceptedCount} / ${metrics.declinedCount}</span></p>
        <p><strong>Total quoted value</strong><span>${money(metrics.totalQuotedValue)}</span></p>
        <p><strong>Accepted load value</strong><span>${money(metrics.acceptedValue)}</span></p>
      </div>
    </div>
  `;
}

function renderRecentActivity(requests: QuoteRequest[]): string {
  const activities = [
    ...requests.slice(0, 5).map((request) => ({
      time: request.createdAt,
      title: request.publicReference ?? request.companyName,
      detail: `${request.companyName} - ${statusLabels[request.status] ?? request.status}`,
      href: `./quote-review.html?id=${request.id}`
    }))
  ]
    .filter((activity) => activity.time)
    .sort((a, b) => String(b.time).localeCompare(String(a.time)))
    .slice(0, 8);

  if (!activities.length) {
    return `
      <div class="empty-state">
        <strong>No recent activity yet</strong>
        <span>RFQs, quotes, declined responses, and accepted loads will appear here as the team works through the quote flow.</span>
      </div>
    `;
  }

  return `
    <div class="activity-list">
      ${activities.map((activity) => `
        <a class="activity-item" href="${escapeHtml(activity.href)}">
          <span></span>
          <div>
            <strong>${escapeHtml(activity.title)}</strong>
            <small>${escapeHtml(activity.detail)}</small>
          </div>
          <time>${escapeHtml(formatDateTime(activity.time))}</time>
        </a>
      `).join("")}
    </div>
  `;
}

function renderDashboardActions(user: InternalUserRecord, metrics: {
  quoteRequestCount: number;
  reviewCount: number;
  sentCount: number;
  declinedCount: number;
  acceptedCount: number;
}): string {
  const canManageRfqs = user.role === "owner" || user.can_manage_rfqs;
  const canViewOperations = user.role === "owner" || user.can_view_all_quotes || user.can_manage_rfqs;
  const canManagePricing = user.role === "owner" || user.can_manage_pricing_rules;
  const canManageUsers = user.role === "owner" || user.can_manage_users;
  const canReadSettings = user.role === "owner" || user.role === "manager" || user.can_manage_users || user.can_manage_rfqs;
  const actionCards = [
    canManageRfqs ? ["Quote Requests", "./quote-review.html?status=client_submitted", `${metrics.quoteRequestCount} new`, "rfq"] : null,
    canViewOperations ? ["Quotes", "./quote-review.html", `${metrics.reviewCount} awaiting review`, "review"] : null,
    canViewOperations ? ["Accepted Loads", "./accepted-loads.html", `${metrics.acceptedCount} accepted`, "accepted"] : null,
    canViewOperations ? ["Rejected Review", "./quote-review.html?status=client_declined", `${metrics.declinedCount} declined`, "warning"] : null,
    canManagePricing ? ["Pricing Settings", "./pricing-settings.html", "Dynamic pricing configuration", "money"] : null,
    canViewOperations ? ["Customers", "./customers.html", "RFQ and quote customer history", "sent"] : null,
    canManageUsers ? ["Users", "./users-dashboard.html", "Manage internal access", "accepted"] : null,
    canReadSettings ? ["Settings", "./admin-settings.html", "Branding, templates, numbering", "review"] : null
  ].filter(Boolean) as string[][];

  if (!actionCards.length) {
    return `<p class="muted">No quick actions are available for your current role. Ask an owner to review your internal permissions.</p>`;
  }

  return actionCards.map(([label, href, helper, icon]) => `
    <a class="action-card" href="${href}">
      <span class="action-icon">${dashboardIcon(icon)}</span>
      <span>
        <strong>${escapeHtml(label)}</strong>
        <small>${escapeHtml(helper)}</small>
      </span>
    </a>
  `).join("");
}

async function initJobs(): Promise<void> {
  const list = document.querySelector<HTMLElement>("#jobsList");
  if (!list) return;

  if (!isSupabaseConfigured) {
    list.innerHTML = `<p class="muted">Connect Supabase to list accepted loads.</p>`;
    return;
  }

  try {
    const records = await loadAdminQuoteRequests();
    const acceptedRequests = records
      .map(requestFromRecord)
      .filter((request) => request.transportJob || ["client_accepted", "converted_to_load"].includes(request.status));
    list.innerHTML = acceptedRequests.length
      ? acceptedRequests.map(renderAcceptedLoadCard).join("")
      : `<p class="muted">No accepted loads are available. Customer accepted quotes will appear here automatically with one order/load number.</p>`;
  } catch (error) {
    list.innerHTML = `<p class="muted">Accepted loads could not load: ${escapeHtml(friendlyError(error))}</p>`;
  }
}

async function initCustomers(): Promise<void> {
  const list = document.querySelector<HTMLElement>("#customersList");
  if (!list) return;

  if (!isSupabaseConfigured) {
    list.innerHTML = `<p class="muted">Connect Supabase to summarize customers from submitted RFQs and quotes.</p>`;
    return;
  }

  try {
    const records = await loadAdminQuoteRequests();
    const requests = records.map(requestFromRecord);
    const customerMap = new Map<string, { company: string; contact: string; email: string; phone: string; count: number; accepted: number; latest: string; latestId: string }>();
    requests.forEach((request) => {
      const key = request.email.toLowerCase() || request.companyName.toLowerCase();
      const current = customerMap.get(key) ?? {
        company: request.companyName,
        contact: request.contactPerson,
        email: request.email,
        phone: request.phone,
        count: 0,
        accepted: 0,
        latest: request.createdAt,
        latestId: request.id
      };
      current.count += 1;
      if (request.status === "client_accepted" || request.status === "converted_to_load") current.accepted += 1;
      if (String(request.createdAt).localeCompare(String(current.latest)) > 0) {
        current.latest = request.createdAt;
        current.latestId = request.id;
      }
      customerMap.set(key, current);
    });

    const customers = Array.from(customerMap.values()).sort((a, b) => String(b.latest).localeCompare(String(a.latest)));
    list.innerHTML = customers.length
      ? customers.map((customer) => `
        <article class="quote-row">
          <div>
            <strong>${escapeHtml(customer.company)}</strong>
            <span>${escapeHtml(customer.contact)} - ${escapeHtml(customer.email)}</span>
            <small>${customer.count} RFQ/quote record(s), ${customer.accepted} accepted load(s)</small>
          </div>
          <div>
            <span class="badge">${escapeHtml(formatDateTime(customer.latest))}</span>
            <a class="button small" href="./quote-review.html?id=${customer.latestId}">Latest quote</a>
          </div>
        </article>
      `).join("")
      : `<p class="muted">No customer RFQs have been submitted yet.</p>`;
  } catch (error) {
    list.innerHTML = `<p class="muted">Customers could not load: ${escapeHtml(friendlyError(error))}</p>`;
  }
}

function parseSettingsJson(value: string, fallback: unknown): unknown {
  const trimmed = value.trim();
  if (!trimmed) return fallback;
  return JSON.parse(trimmed) as unknown;
}

function buildSettingsPayloadFromForm(form: HTMLFormElement, current: InternalSettingsPayload): InternalSettingsPayload {
  const data = new FormData(form);
  const value = (key: string): string => String(data.get(key) ?? "").trim();
  return {
    ...current,
    company_branding: {
      ...current.company_branding,
      company_name: value("company_name"),
      trading_name: value("trading_name"),
      website_url: value("website_url"),
      logo_url: value("logo_url"),
      primary_color: value("primary_color"),
      accent_color: value("accent_color"),
      contact_email: value("contact_email"),
      contact_phone: value("contact_phone"),
      address: value("address"),
      quote_footer: value("quote_footer")
    },
    system_settings: current.system_settings.map((setting, index) => ({
      ...setting,
      setting_key: value(`system_key_${index}`) || setting.setting_key,
      setting_category: value(`system_category_${index}`) || setting.setting_category,
      display_name: value(`system_display_${index}`) || setting.display_name,
      is_restricted: (value(`system_restricted_${index}`) || String(setting.is_restricted)) === "true",
      setting_value: parseSettingsJson(value(`system_value_${index}`), setting.setting_value) as Record<string, unknown>
    })),
    email_templates: current.email_templates.map((template, index) => ({
      ...template,
      template_key: value(`template_key_${index}`) || template.template_key,
      template_name: value(`template_name_${index}`) || template.template_name,
      subject_placeholder: value(`template_subject_${index}`),
      body_placeholder: value(`template_body_${index}`),
      available_variables: parseSettingsJson(value(`template_variables_${index}`), template.available_variables) as unknown[],
      is_active: data.has(`template_active_${index}`)
    })),
    numbering_sequences: current.numbering_sequences.map((sequence, index) => ({
      ...sequence,
      sequence_key: value(`sequence_key_${index}`) || sequence.sequence_key,
      display_name: value(`sequence_display_${index}`) || sequence.display_name,
      prefix: value(`sequence_prefix_${index}`),
      next_number: Math.max(Number(value(`sequence_next_${index}`)) || sequence.next_number || 1, 1),
      padding: Math.min(Math.max(Number(value(`sequence_padding_${index}`)) || sequence.padding || 5, 1), 12),
      suffix: value(`sequence_suffix_${index}`) || null
    }))
  };
}

async function initAdminSettings(): Promise<void> {
  const content = document.querySelector<HTMLElement>("#adminSettingsContent");
  if (!content) return;

  if (!isSupabaseConfigured) {
    content.innerHTML = `<p class="muted">Connect Supabase to load audited admin settings.</p>`;
    return;
  }

  try {
    const settings = await loadInternalSettings();
    if (!settings) {
      content.innerHTML = `<p class="muted">No settings are available for this internal user.</p>`;
      return;
    }

    content.innerHTML = renderAdminSettings(settings);
    const form = document.querySelector<HTMLFormElement>("#adminSettingsForm");
    const output = document.querySelector<HTMLElement>("#adminSettingsOutput");
    if (!form || !output || !settings.can_update) return;

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      try {
        const payload = buildSettingsPayloadFromForm(form, settings);
        const updated = await updateInternalSettings(payload);
        content.innerHTML = renderAdminSettings(updated);
      } catch (error) {
        output.innerHTML = `<strong>Settings not saved.</strong><span>${escapeHtml(friendlyError(error, "Settings could not be saved. Please check the JSON fields and try again."))}</span>`;
      }
    });
  } catch (error) {
    content.innerHTML = `<p class="muted">Settings could not load: ${escapeHtml(friendlyError(error))}</p>`;
  }
}

async function initUsersDashboard(): Promise<void> {
  const list = document.querySelector<HTMLElement>("#usersList");
  const form = document.querySelector<HTMLFormElement>("#inviteUserForm");
  const output = document.querySelector<HTMLElement>("#usersOutput");
  if (!list || !form || !output) return;

  if (!isSupabaseConfigured) {
    list.innerHTML = `<p class="muted">Connect the production backend before managing internal portal users.</p>`;
    form.hidden = true;
    return;
  }

  const canManage = currentInternalUser?.role === "owner" || Boolean(currentInternalUser?.can_manage_users);

  const render = async () => {
    list.innerHTML = skeletonCards(3);
    let users: InternalUserRecord[] = [];
    try {
      users = await listInternalUsers();
    } catch (error) {
      list.innerHTML = `<p class="muted">Internal users could not load: ${escapeHtml(friendlyError(error, "Check your user-management permissions and Supabase connection."))}</p>`;
      return;
    }

    list.innerHTML = users.length ? users.map((user) => `
      <article class="quote-row">
        <div>
          <strong>${escapeHtml(user.full_name || user.email)}</strong>
          <span>${escapeHtml(user.email)}</span>
          <small>${escapeHtml(roleDescription(user.role))}</small>
          <small>Created ${escapeHtml(formatDateTime(user.created_at))} - Last login ${escapeHtml(formatDateTime(user.last_login_at))}</small>
        </div>
        <div>
          <span class="badge">${escapeHtml(user.role)}</span>
          <span class="badge">${escapeHtml(user.user_status)}</span>
          ${canManage && user.user_status === "active" ? `<button class="small" type="button" data-revoke-user="${escapeHtml(user.id)}">Revoke</button>` : ""}
          ${canManage && user.user_status === "revoked" ? `<button class="small" type="button" data-reactivate-user="${escapeHtml(user.id)}">Reactivate</button>` : ""}
        </div>
      </article>
    `).join("") : `<div class="empty-state"><strong>No internal users visible</strong><span>Create a secure login user first, then add the matching user ID here.</span></div>`;

    list.querySelectorAll<HTMLButtonElement>("[data-revoke-user]").forEach((button) => {
      button.addEventListener("click", async () => {
        try {
          await revokeInternalUser(button.dataset.revokeUser ?? "");
          output.innerHTML = `<strong>User revoked.</strong><span>Internal access has been disabled while audit history is preserved.</span>`;
          await render();
        } catch (error) {
          output.innerHTML = `<strong>Revoke failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
        }
      });
    });

    list.querySelectorAll<HTMLButtonElement>("[data-reactivate-user]").forEach((button) => {
      button.addEventListener("click", async () => {
        try {
          await reactivateInternalUser(button.dataset.reactivateUser ?? "");
          output.innerHTML = `<strong>User reactivated.</strong><span>Internal access is active again for this Auth user.</span>`;
          await render();
        } catch (error) {
          output.innerHTML = `<strong>Reactivate failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
        }
      });
    });
  };

  if (!canManage) {
    form.hidden = true;
    output.innerHTML = `<strong>Read-only access.</strong><span>Your role can view visible internal users but cannot add, revoke, or reactivate access.</span>`;
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(form);
    const role = formValue(data, "role") as InternalRole;
    const authUserId = formValue(data, "authUserId");
    const roleDefaults = {
      canViewAllQuotes: ["owner", "manager", "viewer"].includes(role),
      canManageRfqs: ["owner", "manager"].includes(role),
      canApproveQuotes: ["owner", "manager"].includes(role),
      canAdjustPricing: role === "owner",
      canManagePricingRules: role === "owner",
      canManageUsers: role === "owner"
    };
    if (!authUserId) {
      output.innerHTML = `<strong>Login user ID required.</strong><span>Create the secure login user first, then paste the matching user UUID here.</span>`;
      return;
    }
    try {
      await saveInternalUser({
        id: authUserId,
        fullName: formValue(data, "fullName"),
        email: formValue(data, "email"),
        role,
        canViewAllQuotes: roleDefaults.canViewAllQuotes || Boolean(data.get("canViewAllQuotes")),
        canManageRfqs: roleDefaults.canManageRfqs || Boolean(data.get("canManageRfqs")),
        canApproveQuotes: roleDefaults.canApproveQuotes || Boolean(data.get("canApproveQuotes")),
        canAdjustPricing: roleDefaults.canAdjustPricing || Boolean(data.get("canAdjustPricing")),
        canManagePricingRules: roleDefaults.canManagePricingRules || Boolean(data.get("canManagePricingRules")),
        canManageUsers: roleDefaults.canManageUsers || Boolean(data.get("canManageUsers"))
      });
      output.innerHTML = `<strong>User access saved.</strong><span>The portal access record now matches the secure login user.</span>`;
      form.reset();
      await render();
    } catch (error) {
      output.innerHTML = `<strong>User access not saved.</strong><span>${escapeHtml(friendlyError(error, "Confirm the Auth user ID exists and your role can manage users."))}</span>`;
    }
  });

  await render();
}

function initPricingSettings(): void {
  const form = document.querySelector<HTMLFormElement>("#pricingSettingsForm");
  const output = document.querySelector<HTMLElement>("#pricingSettingsOutput");
  if (!form || !output) return;
  const equipmentProfilesList = document.querySelector<HTMLElement>("#equipmentProfilesList");

  if (equipmentProfilesList) {
    if (isSupabaseConfigured) {
      void listStandardEquipmentProfiles()
        .then((profiles) => {
          equipmentProfilesList.innerHTML = profiles.length
            ? profiles.map(renderEquipmentProfileRow).join("")
            : `<p class="muted">No active standard equipment profiles found.</p>`;
        })
        .catch((error) => {
          equipmentProfilesList.innerHTML = `<p class="muted">Equipment profiles could not load: ${escapeHtml(friendlyError(error))}</p>`;
        });
    } else {
      equipmentProfilesList.innerHTML = `<p class="muted">Connect Supabase to load the production equipment catalogue.</p>`;
    }
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(form);
    const value = (key: string) => String(data.get(key) ?? "").trim();
    const payload = {
      fuel_price_per_litre: value("fuel_price_per_litre"),
      diesel_previous_price_per_litre: value("diesel_previous_price_per_litre"),
      fuel_consumption_l_per_100km: value("fuel_consumption_l_per_100km"),
      average_tyre_cost_per_km: value("average_tyre_cost_per_km"),
      maintenance_cost_per_km: value("maintenance_cost_per_km"),
      insurance_cost_per_km: value("insurance_cost_per_km"),
      depreciation_cost_per_km: value("depreciation_cost_per_km"),
      vehicle_overhead_per_km: value("vehicle_overhead_per_km"),
      driver_hourly_wage: value("driver_hourly_wage"),
      driver_overnight_allowance: value("driver_overnight_allowance"),
      admin_overhead_percent: value("admin_overhead_percent"),
      profit_margin_percent: value("profit_margin_percent"),
      vat_percent: value("vat_percent"),
      minimum_profit: value("minimum_profit"),
      maximum_discount_percent: value("maximum_discount_percent"),
      currency: value("currency") || "ZAR",
      quote_validity_days: value("quote_validity_days") || "7",
      rule_version: "pricing-v2-dynamic",
      diesel_base_price_per_litre: value("diesel_base_price_per_litre"),
      diesel_effective_from: value("diesel_effective_from"),
      diesel_provider_id: value("diesel_provider_id"),
      diesel_refreshed_at: value("diesel_refreshed_at"),
      diesel_surcharge_percent: value("diesel_surcharge_percent"),
      diesel_admin_override_price_per_litre: value("diesel_admin_override_price_per_litre"),
      diesel_manual_override_enabled: value("diesel_manual_override_enabled") || "true",
      fuel_surcharge_enabled: value("fuel_surcharge_enabled") || "true",
      seasonal_low_multiplier: value("seasonal_low_multiplier"),
      seasonal_normal_multiplier: value("seasonal_normal_multiplier"),
      seasonal_busy_multiplier: value("seasonal_busy_multiplier"),
      seasonal_peak_multiplier: value("seasonal_peak_multiplier"),
      default_toll_cost: value("default_toll_cost"),
      default_route_risk_surcharge: value("default_route_risk_surcharge"),
      vehicle_cost_profile_key: value("vehicle_cost_profile_key") || "default",
      margin_profile_key: value("margin_profile_key") || "target",
      margin_profile_percent: value("margin_profile_percent"),
      margin_profile_minimum_profit: value("margin_profile_minimum_profit"),
      surcharges: {
        escort_surcharge: value("escort_surcharge"),
        permit_surcharge: value("permit_surcharge"),
        hazmat_surcharge: value("hazmat_surcharge"),
        refrigeration_surcharge: value("refrigeration_surcharge"),
        crane_surcharge: value("crane_surcharge"),
        forklift_surcharge: value("forklift_surcharge"),
        high_value_threshold: value("high_value_threshold"),
        high_value_surcharge: value("high_value_surcharge")
      }
    };

    if (isSupabaseConfigured) {
      try {
        await savePricingSettings(payload);
        output.innerHTML = `<strong>Pricing settings saved.</strong><span>Future calculations will use the active configurable profile.</span>`;
      } catch (error) {
        output.innerHTML = `<strong>Pricing settings failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
      }
      return;
    }

    window.localStorage.setItem("time-trucking-auto-quote-pricing-settings", JSON.stringify(payload));
    output.innerHTML = `<strong>Pricing settings saved locally.</strong><span>Connect Supabase to persist company pricing rules.</span>`;
  });
}

function renderEquipmentProfileRow(profile: StandardEquipmentProfileRecord): string {
  const flags = [
    profile.enclosed ? "Enclosed" : "",
    profile.open_deck ? "Open deck" : "",
    profile.side_loading ? "Side loading" : "",
    profile.refrigerated ? "Reefer" : "",
    profile.specialist_abnormal ? "Specialist" : ""
  ].filter(Boolean);
  return `
    <article class="equipment-profile-row">
      <div>
        <strong>${escapeHtml(profile.display_name)}</strong>
        <span>${escapeHtml(profile.trailer_body)} - ${escapeHtml(equipmentSourceLabel(profile.equipment_source_default))}</span>
      </div>
      <div class="quote-meta">
        <span>${formatKg(Number(profile.payload_capacity_kg ?? 0))} kg</span>
        <span>${Number(profile.usable_cube_m3 ?? 0)} m3</span>
        <span>${Number(profile.deck_length_m ?? 0)}m x ${Number(profile.deck_width_m ?? 0)}m</span>
      </div>
      <div class="flag-row">${flags.map((flag) => `<span class="flag info">${escapeHtml(flag)}</span>`).join("")}</div>
    </article>
  `;
}

function initCreateLink(): void {
  const form = document.querySelector<HTMLFormElement>("#createLinkForm");
  const output = document.querySelector<HTMLElement>("#linkOutput");
  if (!form || !output) return;

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(form);
    const token = crypto.randomUUID().replaceAll("-", "");
    const url = `${window.location.origin}${window.location.pathname.replace("create-rfq-link.html", "client-rfq.html")}?token=${token}`;
    const email = buildRfqLinkEmail(formValue(data, "email"), url);
    if (isSupabaseConfigured) {
      try {
        await createInternalRfqLink({
          companyName: formValue(data, "companyName"),
          email: formValue(data, "email"),
          referenceNumber: formValue(data, "referenceNumber"),
          expiresOn: formValue(data, "expiresOn"),
          rawToken: token
        });
      } catch (error) {
        output.innerHTML = `<strong>RFQ link not saved.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
        return;
      }
    }
    output.innerHTML = `
      <strong>Secure RFQ link created</strong>
      <span>${escapeHtml(url)}</span>
      <small>Email provider not configured. Message preview: ${escapeHtml(email.subject)} to ${escapeHtml(email.to)}</small>
    `;
  });
}

function initClientRfq(): void {
  const form = document.querySelector<HTMLFormElement>("#clientRfqForm");
  const suggestion = document.querySelector<HTMLElement>("#suggestionPreview");
  const output = document.querySelector<HTMLElement>("#submitOutput");
  if (!form || !suggestion || !output) return;

  const stopsList = document.querySelector<HTMLElement>("#stopsList");
  const cargoItemsList = document.querySelector<HTMLElement>("#cargoItemsList");
  const dynamicQuestionsList = document.querySelector<HTMLElement>("#dynamicQuestionsList");
  const reviewSummary = document.querySelector<HTMLElement>("#rfqReviewSummary");
  const addStopButton = document.querySelector<HTMLButtonElement>("#addStopButton");
  const addCargoItemButton = document.querySelector<HTMLButtonElement>("#addCargoItemButton");
  const prevStepButton = document.querySelector<HTMLButtonElement>("#prevStepButton");
  const nextStepButton = document.querySelector<HTMLButtonElement>("#nextStepButton");
  const saveDraftButton = document.querySelector<HTMLButtonElement>("#saveDraftButton");
  const submitButton = form.querySelector<HTMLButtonElement>('button[type="submit"]');
  const stepButtons = Array.from(document.querySelectorAll<HTMLButtonElement>("[data-step-button]"));
  const panels = Array.from(document.querySelectorAll<HTMLElement>("[data-step]"));

  if (!stopsList || !cargoItemsList || !dynamicQuestionsList || !reviewSummary || !addStopButton || !addCargoItemButton || !prevStepButton || !nextStepButton || !saveDraftButton || !submitButton) return;

  form.noValidate = true;

  let currentStep = 0;
  let stopCounter = 0;
  let cargoCounter = 0;
  let rfqSubmissionInFlight = false;
  let rfqSubmissionComplete = false;
  const submitButtonDefaultText = submitButton.textContent?.trim() || "REQUEST QUOTE";

  const clearValidation = (): void => {
    form.querySelectorAll("[aria-invalid='true']").forEach((field) => field.removeAttribute("aria-invalid"));
    form.querySelectorAll(".validation-message").forEach((message) => message.remove());
  };

  const showValidation = (field: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement | null, message: string): boolean => {
    output.innerHTML = `<strong>Almost there.</strong><span>${escapeHtml(message)}</span>`;
    if (field) {
      field.setAttribute("aria-invalid", "true");
      const label = field.closest("label");
      label?.querySelector(".validation-message")?.remove();
      label?.insertAdjacentHTML("beforeend", `<small class="validation-message">${escapeHtml(message)}</small>`);
      field.scrollIntoView({ behavior: "smooth", block: "center" });
      field.focus();
    }
    return false;
  };

  const namedField = (name: string): HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement | null =>
    form.querySelector<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>(`[name="${name}"]`);

  const visibleQuantityField = (card: HTMLElement): HTMLInputElement | null => {
    const fields = Array.from(card.querySelectorAll<HTMLInputElement>("[data-cargo-quantity]"));
    return fields.find((field) => {
      if (field.closest("[hidden]")) return false;
      const style = window.getComputedStyle(field);
      return style.display !== "none" && style.visibility !== "hidden";
    }) ?? null;
  };

  const positiveInputValue = (field: HTMLInputElement | null | undefined): boolean => {
    const value = Number(field?.value ?? 0);
    return Number.isFinite(value) && value > 0;
  };

  const dimensionInput = (card: HTMLElement, name: "length_m" | "width_m" | "height_m"): HTMLInputElement | null =>
    card.querySelector<HTMLInputElement>(`[data-dimension-field="${name}"]`);

  const dimensionLabel = (name: "length_m" | "width_m" | "height_m"): string => ({
    length_m: "length",
    width_m: "width",
    height_m: "height"
  }[name]);

  const stepValidationIssue = (step: number): { field: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement | null; message: string } | null => {
    const panel = panels.find((item) => Number(item.dataset.step) === step);
    if (!panel) return null;
    if (step === 0) {
      const company = namedField("companyName");
      const contact = namedField("contactPerson");
      const email = namedField("email") as HTMLInputElement | null;
      const phone = namedField("phone");
      if (!company?.value.trim()) return { field: company, message: "Please add your company name." };
      if (!contact?.value.trim()) return { field: contact, message: "Please add a contact person." };
      if (!email?.value.trim() || !email.checkValidity()) return { field: email, message: "Please enter a valid email address." };
      if (!phone?.value.trim()) return { field: phone, message: "Please add a phone number." };
    }
    if (step === 1) {
      const stops = collectStops();
      const collectionCard = stopsList.querySelector<HTMLElement>('[data-primary-stop="collection"]');
      const deliveryCard = stopsList.querySelector<HTMLElement>('[data-primary-stop="delivery"]');
      const collectionField = collectionCard?.querySelector<HTMLInputElement>('[data-stop-field="address"]') ?? null;
      const deliveryField = deliveryCard?.querySelector<HTMLInputElement>('[data-stop-field="address"]') ?? null;
      if (!stops.find((stop) => stop.stop_type === "collection" && stop.address)) return { field: collectionField, message: "Please add the collection address." };
      if (!stops.find((stop) => stop.stop_type === "delivery" && stop.address)) return { field: deliveryField, message: "Please add the delivery address." };
      const collectionDate = namedField("preferredCollectionDate");
      if (!collectionDate?.value.trim()) return { field: collectionDate, message: "Please choose a preferred collection date." };
    }
    if (step === 2) {
      const cargoItems = collectCargoItems();
      const cargoCard = cargoItemsList.querySelector<HTMLElement>("[data-cargo-card]");
      const descriptionField = cargoCard?.querySelector<HTMLInputElement>('[data-cargo-field="description"]') ?? null;
      const totalWeightField = cargoCard?.querySelector<HTMLInputElement>("[data-total-weight]") ?? null;
      const quantityField = cargoCard ? visibleQuantityField(cargoCard) : null;
      if (!cargoItems.length) return { field: null, message: "Please add what you are moving." };
      if (cargoItems.some((item) => !item.description?.trim())) return { field: descriptionField, message: "Please add a cargo description." };
      if (quantityField && Number(quantityField.value) <= 0) return { field: quantityField, message: "Please add a quantity." };
      if (cargoItems.some((item) => itemTotalWeightKg(item) <= 0)) return { field: totalWeightField, message: "Total shipment weight must be more than 0 kg." };
      if (cargoCard && selectedFreightType(cargoCard) === "pallets") {
        for (const name of ["length_m", "width_m", "height_m"] as const) {
          const field = dimensionInput(cargoCard, name);
          if (!positiveInputValue(field)) return { field, message: `Please add the pallet ${dimensionLabel(name)} in millimetres.` };
        }
      }
      if (cargoCard && selectedFreightType(cargoCard) === "abnormal") {
        for (const name of ["length_m", "width_m", "height_m"] as const) {
          const field = dimensionInput(cargoCard, name);
          if (!positiveInputValue(field)) return { field, message: `Please add the load ${dimensionLabel(name)} in millimetres.` };
        }
        const abnormalWeightField = cargoCard.querySelector<HTMLInputElement>("[data-abnormal-weight]");
        if (!positiveInputValue(abnormalWeightField)) return { field: abnormalWeightField, message: "Please add the abnormal-load weight in kg." };
      }
      const insuranceField = namedField("insurance");
      const cargoValueField = namedField("cargoValue") as HTMLInputElement | null;
      if (insuranceField?.value === "yes" && !positiveInputValue(cargoValueField)) {
        return { field: cargoValueField, message: "Please add the cargo value when insurance is required." };
      }
      const notesField = namedField("specialRequirements");
      if (namedField("dangerousGoods") instanceof HTMLInputElement && (namedField("dangerousGoods") as HTMLInputElement).checked && !notesField?.value.trim()) {
        return { field: notesField, message: "Please add dangerous-goods details in the notes." };
      }
      if (namedField("temperatureControlled") instanceof HTMLInputElement && (namedField("temperatureControlled") as HTMLInputElement).checked && !notesField?.value.trim()) {
        return { field: notesField, message: "Please add the required temperature range or details in the notes." };
      }
    }
    return null;
  };

  const validateStep = (step: number): boolean => {
    clearValidation();
    const issue = stepValidationIssue(step);
    if (issue) return showValidation(issue.field, issue.message);
    output.innerHTML = "";
    return true;
  };

  const allRequiredFieldsValid = (): boolean =>
    panels.every((panel) => !stepValidationIssue(Number(panel.dataset.step)));

  const updateSubmitButtonState = (): void => {
    const canSubmit = currentStep === panels.length - 1 && allRequiredFieldsValid();
    submitButton.hidden = currentStep !== panels.length - 1;
    submitButton.disabled = !canSubmit || rfqSubmissionInFlight || rfqSubmissionComplete;
    submitButton.setAttribute("aria-disabled", String(!canSubmit || rfqSubmissionInFlight || rfqSubmissionComplete));
  };

  const setSubmitLoading = (message: string): void => {
    rfqSubmissionInFlight = true;
    submitButton.disabled = true;
    submitButton.setAttribute("aria-disabled", "true");
    submitButton.textContent = "Sending request...";
    output.innerHTML = `<strong>${escapeHtml(message)}</strong><span>Please keep this page open while we create your RFQ.</span>`;
  };

  const clearSubmitLoading = (): void => {
    rfqSubmissionInFlight = false;
    submitButton.textContent = submitButtonDefaultText;
    updateSubmitButtonState();
  };

  const keepSubmitComplete = (): void => {
    rfqSubmissionInFlight = false;
    rfqSubmissionComplete = true;
    submitButton.textContent = "Request received";
    updateSubmitButtonState();
  };

  const setStep = (step: number) => {
    currentStep = Math.max(0, Math.min(step, panels.length - 1));
    panels.forEach((panel) => panel.classList.toggle("active", Number(panel.dataset.step) === currentStep));
    stepButtons.forEach((button) => button.classList.toggle("active", Number(button.dataset.stepButton) === currentStep));
    prevStepButton.hidden = currentStep === 0;
    nextStepButton.hidden = currentStep === panels.length - 1;
    refreshSummary();
    updateSubmitButtonState();
  };

  const stopTemplate = (index: number, type: string, title: string, removable = true) => `
    <article class="nested-card" data-stop-card${removable ? "" : ` data-primary-stop="${type}"`}>
      <header>
        <h3>${title}</h3>
        ${removable ? `<button type="button" data-remove-stop>Remove</button>` : ""}
      </header>
      <input type="hidden" data-stop-field="stop_type" value="${type}" />
      <label>${type === "delivery" ? "Delivery" : type === "collection" ? "Collection" : "Stop address"}<input data-stop-field="address" data-address-autocomplete required placeholder="Start typing an address" /></label>
      <details class="optional-section stop-details">
        <summary>+ ${type === "delivery" ? "Delivery" : type === "collection" ? "Collection" : "Stop"} details</summary>
        <div class="grid two">
          ${removable ? `
            <label>Stop type
              <select data-stop-type-select>
                <option value="collection"${type === "collection" ? " selected" : ""}>Collection</option>
                <option value="delivery"${type === "delivery" ? " selected" : ""}>Delivery</option>
                <option value="warehouse">Warehouse</option>
                <option value="border">Border</option>
                <option value="other"${type === "other" ? " selected" : ""}>Other</option>
              </select>
            </label>
          ` : ""}
          <label>${type === "delivery" ? "Delivery notes" : type === "collection" ? "Collection notes" : "Stop notes"}<textarea data-stop-field="notes" placeholder="Access notes, reference numbers, site contact, or instructions."></textarea></label>
        </div>
      </details>
      <input type="hidden" data-stop-field="stop_order" value="${index}" />
      <input type="hidden" data-stop-field="date_time_window" />
      <input type="hidden" data-stop-field="loading_method" />
      <input type="hidden" data-stop-field="offloading_method" />
      <input type="hidden" data-stop-field="contact_name" />
      <input type="hidden" data-stop-field="contact_phone" />
      <input type="hidden" data-stop-field="latitude" />
      <input type="hidden" data-stop-field="longitude" />
      <input type="hidden" data-stop-field="place_id" />
      <input type="hidden" data-stop-field="formatted_address" />
    </article>
  `;

  const setupAddressAutocompleteForStop = (card: HTMLElement): void => {
    const input = card.querySelector<HTMLInputElement>('[data-stop-field="address"][data-address-autocomplete]');
    if (!input || input.dataset.autocompleteReady === "true" || !googleMapsApiKey) return;
    void loadGoogleMapsLibrary<{ Autocomplete: any }>("places")
      .then((places) => {
        if (!places.Autocomplete) return;
        const instance = new places.Autocomplete(input, {
          fields: ["formatted_address", "geometry", "place_id", "name"],
          componentRestrictions: { country: ["za"] }
        });
        input.dataset.autocompleteReady = "true";
        instance.addListener("place_changed", () => {
          const place = instance.getPlace();
          const setField = (name: string, value: string) => {
            const field = card.querySelector<HTMLInputElement>(`[data-stop-field="${name}"]`);
            if (field) field.value = value;
          };
          const lat = place.geometry?.location?.lat?.();
          const lng = place.geometry?.location?.lng?.();
          if (place.formatted_address) {
            input.value = place.formatted_address;
            setField("formatted_address", place.formatted_address);
          }
          setField("place_id", place.place_id ?? "");
          setField("latitude", Number.isFinite(lat) ? String(lat) : "");
          setField("longitude", Number.isFinite(lng) ? String(lng) : "");
          refreshSummary();
        });
      })
      .catch(() => {
        input.placeholder = "Enter address manually";
      });
  };

  const cargoTemplate = (key: string, title: string) => `
    <article class="nested-card compact-cargo-card" data-cargo-card data-client-item-key="${key}">
      <header>
        <h3>${title}</h3>
      </header>
      <fieldset class="freight-choice-group">
        <legend>Freight type</legend>
        <label><input type="radio" name="freightType-${key}" data-freight-type value="pallets" checked /> Pallets / palletised goods</label>
        <label><input type="radio" name="freightType-${key}" data-freight-type value="cartons" /> Cartons / boxes</label>
        <label><input type="radio" name="freightType-${key}" data-freight-type value="general" /> General freight</label>
        <label><input type="radio" name="freightType-${key}" data-freight-type value="part_load" /> Part load</label>
        <label><input type="radio" name="freightType-${key}" data-freight-type value="full_load" /> Full load</label>
        <label><input type="radio" name="freightType-${key}" data-freight-type value="machinery" /> Machinery / equipment</label>
        <label><input type="radio" name="freightType-${key}" data-freight-type value="produce" /> Produce</label>
        <label><input type="radio" name="freightType-${key}" data-freight-type value="abnormal" /> Abnormal / oversized</label>
        <label><input type="radio" name="freightType-${key}" data-freight-type value="other" /> Other</label>
      </fieldset>
      <div class="grid two">
        <label>Cargo description<input data-cargo-field="description" required placeholder="e.g. 12 pallets of packaged goods" /></label>
        <label>Approximate TOTAL shipment weight (kg)<input data-total-weight type="number" min="0" step="0.01" required placeholder="21000" /></label>
      </div>
      <label class="checkbox advanced-weight-toggle"><input data-weight-per-item-toggle type="checkbox" /> Enter weight per item instead</label>
      <div class="grid two weight-per-item-fields" hidden>
        <label>Quantity<input data-cargo-quantity type="number" min="1" value="1" /></label>
        <label>Item weight (kg)<input data-item-weight type="number" min="0" step="0.01" /></label>
      </div>
      <div class="conditional-cargo-fields" data-conditional-fields></div>
      <input type="hidden" data-cargo-field="cargo_category" value="general_freight" />
      <input type="hidden" data-cargo-field="quantity" value="1" />
      <input type="hidden" data-cargo-field="length_m" />
      <input type="hidden" data-cargo-field="width_m" />
      <input type="hidden" data-cargo-field="height_m" />
      <input type="hidden" data-cargo-field="weight_kg" />
      <input type="hidden" data-cargo-field="cargo_value" />
      <input type="hidden" data-cargo-field="stackable" value="no" />
      <input type="hidden" data-cargo-field="fragile" value="no" />
      <input type="hidden" data-cargo-field="dangerous_goods" value="no" />
      <input type="hidden" data-cargo-field="temperature_controlled" value="no" />
      <input type="hidden" data-cargo-field="notes" />
    </article>
  `;

  const freightCategory = (freightType: string): CargoCategory => {
    if (freightType === "machinery" || freightType === "abnormal") return "machinery";
    if (freightType === "produce") return "refrigerated";
    if (freightType === "other") return "other";
    return "general_freight";
  };

  const freightLoadType = (freightType: string): LoadServiceType =>
    freightType === "full_load" || freightType === "abnormal" ? "dedicated" : "part_load";

  const freightLabel = (freightType: string): string => ({
    pallets: "Pallets / palletised goods",
    cartons: "Cartons / boxes",
    general: "General freight",
    part_load: "Part load",
    full_load: "Full load",
    machinery: "Machinery / equipment",
    produce: "Produce",
    abnormal: "Abnormal / oversized",
    other: "Other"
  }[freightType] ?? "General freight");

  const selectedFreightType = (card: HTMLElement): string =>
    card.querySelector<HTMLInputElement>("[data-freight-type]:checked")?.value ?? "pallets";

  const renderConditionalCargoFields = (card: HTMLElement): void => {
    const target = card.querySelector<HTMLElement>("[data-conditional-fields]");
    if (!target) return;
    const type = selectedFreightType(card);
    if (type === "pallets") {
      target.innerHTML = `
        <details class="optional-section" open>
          <summary>Pallet details</summary>
          <div class="grid three">
            <label>Number of pallets<input data-cargo-quantity type="number" min="1" value="1" /></label>
            <label>Pallet length (mm)<input data-dimension-field="length_m" data-dimension-unit="mm" type="number" min="1" step="1" required placeholder="1200" /></label>
            <label>Pallet width (mm)<input data-dimension-field="width_m" data-dimension-unit="mm" type="number" min="1" step="1" required placeholder="1000" /></label>
            <label>Pallet height (mm)<input data-dimension-field="height_m" data-dimension-unit="mm" type="number" min="1" step="1" required placeholder="1500" /></label>
          </div>
        </details>
      `;
    } else if (type === "cartons") {
      target.innerHTML = `
        <details class="optional-section" open>
          <summary>Carton details</summary>
          <div class="grid two">
            <label>Number of cartons<input data-cargo-quantity type="number" min="1" value="1" /></label>
            <label>Carton dimensions optional<input data-dimension-note placeholder="Average carton size" /></label>
          </div>
        </details>
      `;
    } else if (type === "machinery") {
      target.innerHTML = `
        <details class="optional-section" open>
          <summary>Machinery details</summary>
          <div class="grid two">
            <label>Quantity<input data-cargo-quantity type="number" min="1" value="1" /></label>
            <label>Dimensions optional<input data-dimension-note placeholder="Length x width x height" /></label>
          </div>
        </details>
      `;
    } else if (type === "abnormal") {
      target.innerHTML = `
        <details class="optional-section" open>
          <summary>Abnormal-load detail</summary>
          <div class="grid three">
            <label>Length (mm)<input data-dimension-field="length_m" data-dimension-unit="mm" type="number" min="1" step="1" required /></label>
            <label>Width (mm)<input data-dimension-field="width_m" data-dimension-unit="mm" type="number" min="1" step="1" required /></label>
            <label>Height (mm)<input data-dimension-field="height_m" data-dimension-unit="mm" type="number" min="1" step="1" required /></label>
            <label>Weight (kg)<input data-abnormal-weight type="number" min="0" step="0.01" /></label>
          </div>
          <label>Abnormal-load detail<textarea data-cargo-extra-note placeholder="Permits, escorts, over-height/over-width notes, or lifting constraints."></textarea></label>
        </details>
      `;
    } else {
      target.innerHTML = "";
    }
  };

  const syncCargoCard = (card: HTMLElement): void => {
    const field = (name: string) => card.querySelector<HTMLInputElement>(`[data-cargo-field="${name}"]`);
    const totalWeight = Number(card.querySelector<HTMLInputElement>("[data-total-weight]")?.value ?? 0) || 0;
    const perItem = card.querySelector<HTMLInputElement>("[data-weight-per-item-toggle]")?.checked ?? false;
    const quantityFields = Array.from(card.querySelectorAll<HTMLInputElement>("[data-cargo-quantity]"));
    const visibleQuantityFields = quantityFields.filter((input) => !input.closest("[hidden]"));
    const quantityInput = perItem
      ? visibleQuantityFields[0] ?? quantityFields[0]
      : visibleQuantityFields.at(-1) ?? quantityFields.at(-1);
    const quantity = Number(quantityInput?.value ?? 1) || 1;
    const itemWeight = Number(card.querySelector<HTMLInputElement>("[data-item-weight]")?.value ?? 0) || 0;
    const freightType = selectedFreightType(card);
    const dimensionNote = card.querySelector<HTMLInputElement>("[data-dimension-note]")?.value.trim() ?? "";
    const extraNote = card.querySelector<HTMLTextAreaElement>("[data-cargo-extra-note]")?.value.trim() ?? "";
    const dimensionValue = (name: string) => {
      const input = card.querySelector<HTMLInputElement>(`[data-dimension-field="${name}"]`);
      if (!input) return "";
      const value = Number(input.value);
      if (!Number.isFinite(value) || value <= 0) return "";
      return input.dataset.dimensionUnit === "mm" ? String(value / 1000) : String(value);
    };
    const dimensionNoteFromFields = () => {
      const values = (["length_m", "width_m", "height_m"] as const).map((name) => {
        const input = card.querySelector<HTMLInputElement>(`[data-dimension-field="${name}"]`);
        const value = Number(input?.value ?? 0);
        return Number.isFinite(value) && value > 0 ? value : 0;
      });
      return values.every((value) => value > 0) ? `${values[0]}mm x ${values[1]}mm x ${values[2]}mm` : "";
    };
    const abnormalWeight = Number(card.querySelector<HTMLInputElement>("[data-abnormal-weight]")?.value ?? 0) || 0;
    const totalShipmentWeight = perItem ? quantity * itemWeight : totalWeight;
    const storedItemWeight = freightType === "abnormal" && abnormalWeight > 0
      ? abnormalWeight
      : perItem ? itemWeight : (quantity > 0 ? totalWeight / quantity : totalWeight);
    const notes = [
      `Freight type: ${freightLabel(freightType)}`,
      `Weight mode: ${perItem ? "per item" : "total shipment"}`,
      totalShipmentWeight > 0 ? `Total shipment weight: ${formatKg(totalShipmentWeight)} kg` : "",
      dimensionNoteFromFields() ? `Dimensions: ${dimensionNoteFromFields()}` : dimensionNote ? `Dimensions: ${dimensionNote}` : "",
      abnormalWeight > 0 ? `Abnormal item weight: ${formatKg(abnormalWeight)} kg` : "",
      extraNote
    ].filter(Boolean).join(" | ");
    const set = (name: string, value: string) => {
      const input = field(name);
      if (input) input.value = value;
    };
    set("cargo_category", freightCategory(freightType));
    set("quantity", String(quantity));
    set("length_m", dimensionValue("length_m"));
    set("width_m", dimensionValue("width_m"));
    set("height_m", dimensionValue("height_m"));
    set("weight_kg", String(storedItemWeight));
    set("notes", notes);
  };

  const addStop = (type = "other", title?: string, removable = true) => {
    stopCounter += 1;
    stopsList.insertAdjacentHTML("beforeend", stopTemplate(stopCounter, type, title ?? `Stop ${stopCounter}`, removable));
    const card = stopsList.querySelector<HTMLElement>("[data-stop-card]:last-child");
    if (card) setupAddressAutocompleteForStop(card);
    refreshSummary();
  };

  const addCargoItem = () => {
    cargoCounter += 1;
    cargoItemsList.insertAdjacentHTML("beforeend", cargoTemplate(`item-${cargoCounter}`, `Cargo item ${cargoCounter}`));
    const card = cargoItemsList.querySelector<HTMLElement>("[data-cargo-card]:last-child");
    if (card) {
      renderConditionalCargoFields(card);
      syncCargoCard(card);
    }
    refreshDynamicQuestions();
    refreshSummary();
  };

  const selectedMethodValue = (card: HTMLElement, fieldName: "loading_method" | "offloading_method"): string => {
    const method = card.querySelector<HTMLSelectElement>(`[data-stop-method="${fieldName}"]`)?.value.trim() ?? "";
    const detail = card.querySelector<HTMLInputElement>(`[data-method-detail="${fieldName}"]`)?.value.trim() ?? "";
    if (method === "Other / Not sure" && detail) return `${method}: ${detail}`;
    return method;
  };

  const selectedDateTimeWindow = (card: HTMLElement): string => {
    const date = card.querySelector<HTMLInputElement>("[data-stop-date]")?.value.trim() ?? "";
    const windowValue = card.querySelector<HTMLSelectElement>("[data-stop-time-window]")?.value.trim() ?? "";
    const specificTime = card.querySelector<HTMLInputElement>("[data-stop-specific-time]")?.value.trim() ?? "";
    const time = windowValue === "Specific time" ? specificTime : windowValue;
    if (!date && time === "Any time") return "";
    return [date, time].filter(Boolean).join(" ");
  };

  const syncStopDerivedFields = (card: HTMLElement): void => {
    const dateWindowField = card.querySelector<HTMLInputElement>('[data-stop-field="date_time_window"]');
    const loadingField = card.querySelector<HTMLInputElement>('[data-stop-field="loading_method"]');
    const offloadingField = card.querySelector<HTMLInputElement>('[data-stop-field="offloading_method"]');
    if (dateWindowField) dateWindowField.value = selectedDateTimeWindow(card);
    if (loadingField) loadingField.value = selectedMethodValue(card, "loading_method");
    if (offloadingField) offloadingField.value = selectedMethodValue(card, "offloading_method");
  };

  const collectStops = () =>
    Array.from(stopsList.querySelectorAll<HTMLElement>("[data-stop-card]")).map((card, index) => {
      syncStopDerivedFields(card);
      const field = (name: string) => card.querySelector<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>(`[data-stop-field="${name}"]`)?.value.trim() ?? "";
      return {
        stop_order: index + 1,
        sequence_number: index + 1,
        stop_type: field("stop_type") as QuoteStopRecord["stop_type"],
        address: field("address"),
        latitude: Number(field("latitude")) || null,
        longitude: Number(field("longitude")) || null,
        place_id: field("place_id") || null,
        formatted_address: field("formatted_address") || null,
        contact_name: field("contact_name"),
        contact_phone: field("contact_phone"),
        date_time_window: field("date_time_window"),
        loading_method: field("loading_method"),
        offloading_method: field("offloading_method"),
        notes: field("notes")
      };
    });

  const collectCargoItems = (): QuoteItemRecord[] =>
    Array.from(cargoItemsList.querySelectorAll<HTMLElement>("[data-cargo-card]")).map((card) => {
      syncCargoCard(card);
      const field = (name: string) => card.querySelector<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>(`[data-cargo-field="${name}"]`)?.value.trim() ?? "";
      const formChecked = (name: string) => form.querySelector<HTMLInputElement>(`[name="${name}"]`)?.checked ?? false;
      const formNumber = (name: string) => Number(form.querySelector<HTMLInputElement>(`[name="${name}"]`)?.value ?? 0) || 0;
      return {
        id: card.dataset.clientItemKey ?? crypto.randomUUID(),
        quote_request_id: "",
        client_item_key: card.dataset.clientItemKey,
        description: field("description"),
        cargo_category: field("cargo_category") as CargoCategory,
        quantity: Number(field("quantity")) || 1,
        length_m: Number(field("length_m")) || 0,
        width_m: Number(field("width_m")) || 0,
        height_m: Number(field("height_m")) || 0,
        weight_kg: Number(field("weight_kg")) || 0,
        stackable: field("stackable") === "yes",
        fragile: field("fragile") === "yes" || formChecked("fragile"),
        dangerous_goods: field("dangerous_goods") === "yes" || formChecked("dangerousGoods"),
        temperature_controlled: field("temperature_controlled") === "yes" || formChecked("temperatureControlled"),
        cargo_value: formNumber("cargoValue") || Number(field("cargo_value")) || 0,
        notes: field("notes")
      };
    });

  const collectDynamicAnswers = () =>
    Array.from(dynamicQuestionsList.querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>("[data-answer-key]"))
      .map((input) => ({
        client_item_key: input.dataset.clientItemKey ?? "",
        answer_group: input.dataset.answerGroup ?? "",
        question_key: input.dataset.answerKey ?? "",
        answer_value: input.value.trim()
      }))
      .filter((answer) => answer.answer_value.length > 0);

  const dynamicQuestionsForItem = (item: QuoteItemRecord) => {
    const key = item.client_item_key ?? item.id;
    const group = item.cargo_category ?? "general_freight";
    const base = `<div class="nested-card"><header><h3>${escapeHtml(item.description || "Cargo item")}</h3><span class="badge">${escapeHtml(group.replace("_", " "))}</span></header><div class="grid two">`;
    const input = (questionKey: string, label: string, type = "input") =>
      type === "textarea"
        ? `<label>${label}<textarea data-client-item-key="${key}" data-answer-group="${group}" data-answer-key="${questionKey}"></textarea></label>`
        : `<label>${label}<input data-client-item-key="${key}" data-answer-group="${group}" data-answer-key="${questionKey}" /></label>`;
    const select = (questionKey: string, label: string, options: string[]) =>
      `<label>${label}<select data-client-item-key="${key}" data-answer-group="${group}" data-answer-key="${questionKey}">${options.map((option) => `<option value="${option}">${option}</option>`).join("")}</select></label>`;

    const questions: string[] = [];
    if (group === "machinery") {
      questions.push(select("self_propelled", "Self-propelled", ["No", "Yes"]));
      questions.push(select("can_roll", "Can roll", ["No", "Yes"]));
      questions.push(select("crane_required", "Crane required", ["No", "Yes"]));
      questions.push(input("lifting_points", "Lifting points", "textarea"));
    } else if (group === "dangerous_goods") {
      questions.push(input("un_number", "UN number"));
      questions.push(input("hazard_class", "Hazard class"));
      questions.push(input("packing_group", "Packing group"));
      questions.push(input("sds_upload_placeholder", "SDS upload placeholder note", "textarea"));
    } else if (group === "refrigerated") {
      questions.push(select("temperature_type", "Chilled/frozen", ["Chilled", "Frozen"]));
      questions.push(input("required_temperature", "Required temperature"));
      questions.push(select("continuous_monitoring", "Continuous monitoring", ["No", "Yes"]));
    } else {
      questions.push(select("freight_format", "Palletised or loose", ["Palletised", "Loose"]));
      questions.push(select("forklift_available", "Forklift available", ["No", "Yes"]));
    }

    return `${base}${questions.join("")}</div></div>`;
  };

  const refreshDynamicQuestions = () => {
    dynamicQuestionsList.innerHTML = "";
  };

  const buildPayload = (isFinal: boolean) => {
    const data = new FormData(form);
    const stops = collectStops();
    const cargoItems = collectCargoItems();
    const firstItem = cargoItems[0];
    const firstCollection = stops.find((stop) => stop.stop_type === "collection") ?? stops[0];
    const firstDelivery = stops.find((stop) => stop.stop_type === "delivery") ?? stops[1];
    const insurance = formValue(data, "insurance") === "yes";
    const firstCargoCard = cargoItemsList.querySelector<HTMLElement>("[data-cargo-card]");
    const freightType = firstCargoCard ? selectedFreightType(firstCargoCard) : "pallets";
    const loadType = freightLoadType(freightType);
    const vehicle = calculateWizardSuggestion(cargoItems, loadType, insurance);
    const checked = (name: string) => form.querySelector<HTMLInputElement>(`[name="${name}"]`)?.checked ?? false;
    const selectedTime = (windowName: string, specificName: string) => {
      const value = formValue(data, windowName);
      return value === "Specific time" ? formValue(data, specificName) : value;
    };
    const formatWindow = (dateValue: string, timeValue: string) => {
      if (!dateValue && !timeValue) return "";
      return [dateValue, timeValue || "Any time"].filter(Boolean).join(" ");
    };
    const collectionDate = formValue(data, "preferredCollectionDate");
    const deliveryDate = formValue(data, "deliveryDate");
    const collectionTime = selectedTime("collectionTimeWindow", "collectionSpecificTime");
    const deliveryTime = selectedTime("deliveryTimeWindow", "deliverySpecificTime");
    const requirements = [
      checked("dangerousGoods") ? "Dangerous goods" : "",
      checked("crossBorder") ? "Cross-border" : "",
      checked("repeatLane") ? "Regular/repeat lane" : "",
      checked("temperatureControlled") ? "Temperature controlled" : "",
      formValue(data, "loadingEquipment") ? `Loading equipment: ${formValue(data, "loadingEquipment")}` : "",
      formValue(data, "offloadingEquipment") ? `Offloading equipment: ${formValue(data, "offloadingEquipment")}` : "",
      checked("fragile") ? "Fragile / extra handling" : "",
      formValue(data, "specialRequirements")
    ].filter(Boolean).join(" | ");
    if (firstCollection && collectionDate) firstCollection.date_time_window = formatWindow(collectionDate, collectionTime);
    if (firstDelivery && deliveryDate) firstDelivery.date_time_window = formatWindow(deliveryDate, deliveryTime);
    if (firstCollection && !firstCollection.loading_method) firstCollection.loading_method = formValue(data, "loadingEquipment");
    if (firstDelivery && !firstDelivery.offloading_method) firstDelivery.offloading_method = formValue(data, "offloadingEquipment");

    const payload = {
      company_name: formValue(data, "companyName"),
      contact_person: formValue(data, "contactPerson"),
      email: formValue(data, "email"),
      phone: formValue(data, "phone"),
      collection_address: firstCollection?.address ?? "",
      delivery_address: firstDelivery?.address ?? "",
      cargo_type: firstItem?.cargo_category ?? "general_freight",
      load_description: cargoItems.map((item) => item.description).filter(Boolean).join("; "),
      quantity: firstItem?.quantity ?? 1,
      length_m: firstItem?.length_m ?? 0,
      width_m: firstItem?.width_m ?? 0,
      height_m: firstItem?.height_m ?? 0,
      weight_kg: firstItem ? itemTotalWeightKg(firstItem) : 0,
      stackable: Boolean(firstItem?.stackable),
      load_type: loadType,
      loading_method: firstCollection?.loading_method ?? "",
      offloading_method: firstDelivery?.offloading_method ?? "",
      goods_value: cargoItems.reduce((sum, item) => sum + (item.cargo_value ?? 0), 0),
      insurance_required: insurance,
      collection_date: collectionDate,
      delivery_date: deliveryDate,
      special_requirements: requirements,
      attachment_note: formValue(data, "attachmentNote"),
      suggestion_notes: `${vehicle.suggestedVehicle} / ${vehicle.suggestedTrailer}. ${vehicle.notes}`,
      is_final: isFinal,
      stops,
      cargo_items: cargoItems.map((item) => ({
        client_item_key: item.client_item_key ?? item.id,
        description: item.description ?? "",
        cargo_category: item.cargo_category ?? "general_freight",
        quantity: item.quantity,
        length_m: item.length_m ?? 0,
        width_m: item.width_m ?? 0,
        height_m: item.height_m ?? 0,
        weight_kg: item.weight_kg ?? 0,
        stackable: Boolean(item.stackable),
        fragile: Boolean(item.fragile),
        dangerous_goods: Boolean(item.dangerous_goods),
        temperature_controlled: Boolean(item.temperature_controlled),
        cargo_value: item.cargo_value ?? 0,
        notes: item.notes ?? ""
      })),
      dynamic_answers: collectDynamicAnswers()
    };
    return { payload, vehicle, stops, cargoItems, dynamicAnswers: collectDynamicAnswers() };
  };

  const refreshSummary = () => {
    const { vehicle, stops, cargoItems } = buildPayload(false);
    suggestion.innerHTML = `<strong>${vehicle.suggestedVehicle}</strong><span>${vehicle.suggestedTrailer}</span><small>${vehicle.notes}</small>`;
    const firstCollection = stops.find((stop) => stop.stop_type === "collection") ?? stops[0];
    const firstDelivery = stops.find((stop) => stop.stop_type === "delivery") ?? stops[1];
    const firstItem = cargoItems[0];
    const optionalWhere = [
      firstDelivery?.date_time_window ? `<p><strong>Delivery timing</strong><span>${escapeHtml(firstDelivery.date_time_window)}</span></p>` : "",
      firstCollection?.loading_method ? `<p><strong>Loading</strong><span>${escapeHtml(firstCollection.loading_method)}</span></p>` : "",
      firstDelivery?.offloading_method ? `<p><strong>Offloading</strong><span>${escapeHtml(firstDelivery.offloading_method)}</span></p>` : "",
      firstCollection?.notes ? `<p><strong>Collection notes</strong><span>${escapeHtml(firstCollection.notes)}</span></p>` : "",
      firstDelivery?.notes ? `<p><strong>Delivery notes</strong><span>${escapeHtml(firstDelivery.notes)}</span></p>` : ""
    ].join("");
    const optionalWhat = [
      form.querySelector<HTMLInputElement>("[name='dangerousGoods']")?.checked ? "Dangerous goods" : "",
      form.querySelector<HTMLInputElement>("[name='crossBorder']")?.checked ? "Cross-border" : "",
      form.querySelector<HTMLInputElement>("[name='repeatLane']")?.checked ? "Regular/repeat lane" : "",
      form.querySelector<HTMLInputElement>("[name='temperatureControlled']")?.checked ? "Temperature controlled" : "",
      form.querySelector<HTMLInputElement>("[name='fragile']")?.checked ? "Fragile / extra handling" : "",
      formValue(new FormData(form), "specialRequirements")
    ].filter(Boolean).join(" | ");
    reviewSummary.innerHTML = `
      <div class="summary-block review-summary-card">
        <header><h3>Your details</h3><button type="button" class="button small" data-edit-step="0">Edit</button></header>
        <p><strong>Company</strong><span>${escapeHtml(formValue(new FormData(form), "companyName") || "Not supplied")}</span></p>
        <p><strong>Contact</strong><span>${escapeHtml(formValue(new FormData(form), "contactPerson") || "Not supplied")}</span></p>
        <p><strong>Email</strong><span>${escapeHtml(formValue(new FormData(form), "email") || "Not supplied")}</span></p>
        <p><strong>Phone</strong><span>${escapeHtml(formValue(new FormData(form), "phone") || "Not supplied")}</span></p>
      </div>
      <div class="summary-block review-summary-card">
        <header><h3>Where &amp; when</h3><button type="button" class="button small" data-edit-step="1">Edit</button></header>
        <p><strong>Collection</strong><span>${escapeHtml(firstCollection?.address || "Address pending")}</span></p>
        <p><strong>Delivery</strong><span>${escapeHtml(firstDelivery?.address || "Address pending")}</span></p>
        <p><strong>Collection date</strong><span>${escapeHtml(formValue(new FormData(form), "preferredCollectionDate") || "Date pending")}</span></p>
        ${optionalWhere}
      </div>
      <div class="summary-block review-summary-card">
        <header><h3>What</h3><button type="button" class="button small" data-edit-step="2">Edit</button></header>
        <p><strong>Freight type</strong><span>${escapeHtml(firstItem ? freightLabel(selectedFreightType(cargoItemsList.querySelector<HTMLElement>("[data-cargo-card]")!)) : "Not supplied")}</span></p>
        <p><strong>Description</strong><span>${escapeHtml(firstItem?.description || "Not supplied")}</span></p>
        <p><strong>Quantity</strong><span>${escapeHtml(String(firstItem?.quantity ?? 1))}</span></p>
        <p><strong>Total shipment weight</strong><span>${formatKg(firstItem ? itemTotalWeightKg(firstItem) : 0)} kg</span></p>
        ${optionalWhat ? `<p><strong>Optional details</strong><span>${escapeHtml(optionalWhat)}</span></p>` : ""}
      </div>
    `;
  };

  const submitWizard = async (isFinal: boolean) => {
    if (rfqSubmissionInFlight) return;
    const { payload, vehicle } = buildPayload(isFinal);
    const rawToken = new URLSearchParams(window.location.search).get("token");
    if (isFinal) setSubmitLoading("Sending your request...");

    if (isSupabaseConfigured) {
      try {
        const result = await submitPublicRfq(rawToken, payload);
        if (isFinal) {
          output.innerHTML = `<strong>Thanks - your quote request has been received.</strong><span>Reference: ${escapeHtml(result.public_reference)}</span><span>Our team will review your request and send your quote shortly.</span>`;
          keepSubmitComplete();
          void autoRouteSubmittedRfq({
              quoteRequestId: result.quote_request_id,
              responseToken: result.response_token,
              publicReference: result.public_reference
            }).catch((error) => console.warn("Route automation did not complete", error));
          return;
        }
        output.innerHTML = isFinal
          ? `<strong>Thanks - your quote request has been received.</strong><span>Reference: ${escapeHtml(result.public_reference)}</span><span>Our team will review your request and send your quote shortly.</span>`
          : `<strong>Draft saved.</strong><span>Reference: ${escapeHtml(result.public_reference)}</span>`;
      } catch (error) {
        console.warn("Public RFQ submission failed", error);
        output.innerHTML = `<strong>We could not submit your quote request.</strong><span>Please check the required fields and try again.</span>`;
      } finally {
        if (isFinal && !rfqSubmissionComplete) clearSubmitLoading();
      }
      return;
    }

    const request: QuoteRequest = {
      id: crypto.randomUUID(),
      status: isFinal ? "admin_review" : "draft",
      companyName: payload.company_name,
      contactPerson: payload.contact_person,
      email: payload.email,
      phone: payload.phone,
      collectionAddress: payload.collection_address,
      deliveryAddress: payload.delivery_address,
      cargoType: payload.cargo_type,
      loadDescription: payload.load_description,
      quantity: payload.quantity,
      length: payload.length_m,
      width: payload.width_m,
      height: payload.height_m,
      weight: payload.weight_kg,
      stackable: payload.stackable,
      loadType: payload.load_type,
      loadingMethod: payload.loading_method,
      offloadingMethod: payload.offloading_method,
      goodsValue: payload.goods_value,
      insurance: payload.insurance_required,
      collectionDate: payload.collection_date,
      deliveryDate: payload.delivery_date,
      specialRequirements: payload.special_requirements,
      attachmentNote: payload.attachment_note,
      suggestedVehicle: vehicle.suggestedVehicle,
      suggestedTrailer: vehicle.suggestedTrailer,
      adminNotes: "",
      quotePrice: null,
      stops: payload.stops.map((stop) => ({ id: crypto.randomUUID(), quote_request_id: "", ...stop })),
      items: payload.cargo_items.map((item) => ({ id: item.client_item_key, quote_request_id: "", ...item })),
      dynamicAnswers: payload.dynamic_answers.map((answer) => ({ id: crypto.randomUUID(), quote_request_id: "", cargo_item_id: null, ...answer })),
      createdAt: new Date().toISOString()
    };
    writeRequests([request, ...readRequests()]);
    output.innerHTML = isFinal
      ? `<strong>Thanks - your quote request has been received.</strong><span>Reference: Local draft</span><span>Our team will review your request and send your quote shortly.</span>`
      : `<strong>Draft saved.</strong><span>The secure RFQ token remains valid for continuing later.</span>`;
    if (isFinal) keepSubmitComplete();
  };

  const submitFinalRequest = (): void => {
    if (rfqSubmissionInFlight || rfqSubmissionComplete) return;
    if (currentStep !== panels.length - 1) {
      setStep(panels.length - 1);
      output.innerHTML = `<strong>Almost there.</strong><span>Please review your details before requesting a quote.</span>`;
      updateSubmitButtonState();
      return;
    }
    const invalidStep = panels.find((panel) => !validateStep(Number(panel.dataset.step)));
    if (invalidStep) {
      setStep(Number(invalidStep.dataset.step));
      return;
    }
    if (submitButton.disabled) {
      output.innerHTML = `<strong>Almost there.</strong><span>Please complete the required fields before requesting a quote.</span>`;
      return;
    }
    void submitWizard(true);
  };

  form.addEventListener("input", refreshSummary);
  form.addEventListener("input", () => {
    form.querySelectorAll("[aria-invalid='true']").forEach((field) => field.removeAttribute("aria-invalid"));
    form.querySelectorAll(".validation-message").forEach((message) => message.remove());
    updateSubmitButtonState();
  });
  form.addEventListener("change", (event) => {
    const target = event.target as HTMLElement;
    if (target.matches("[data-time-window-control]")) {
      const label = target.closest("label");
      const specificTimeField = label?.nextElementSibling as HTMLElement | null;
      if (specificTimeField?.classList.contains("specific-time-field")) {
        specificTimeField.hidden = (target as HTMLSelectElement).value !== "Specific time";
      }
    }
    refreshSummary();
    updateSubmitButtonState();
  });
  cargoItemsList.addEventListener("change", (event) => {
    const target = event.target as HTMLElement;
    const card = target.closest<HTMLElement>("[data-cargo-card]");
    if (!card) return;
    if (target.matches("[data-freight-type]")) {
      renderConditionalCargoFields(card);
      syncCargoCard(card);
      refreshDynamicQuestions();
    }
    if (target.matches("[data-weight-per-item-toggle]")) {
      const weightFields = card.querySelector<HTMLElement>(".weight-per-item-fields");
      if (weightFields) weightFields.hidden = !(target as HTMLInputElement).checked;
    }
    syncCargoCard(card);
    refreshSummary();
    updateSubmitButtonState();
  });
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    submitFinalRequest();
  });
  submitButton.addEventListener("click", (event) => {
    event.preventDefault();
    submitFinalRequest();
  });
  saveDraftButton.addEventListener("click", () => void submitWizard(false));
  addStopButton.addEventListener("click", () => {
    addStop();
    updateSubmitButtonState();
  });
  addCargoItemButton.addEventListener("click", () => {
    addCargoItem();
    updateSubmitButtonState();
  });
  prevStepButton.addEventListener("click", () => setStep(currentStep - 1));
  nextStepButton.addEventListener("click", () => {
    if (validateStep(currentStep)) setStep(currentStep + 1);
  });
  stepButtons.forEach((button) => button.addEventListener("click", () => {
    const requestedStep = Number(button.dataset.stepButton);
    if (requestedStep <= currentStep) {
      setStep(requestedStep);
      return;
    }
    for (let step = 0; step < requestedStep; step += 1) {
      if (!validateStep(step)) {
        setStep(step);
        return;
      }
    }
    setStep(requestedStep);
  }));
  reviewSummary.addEventListener("click", (event) => {
    const target = event.target as HTMLElement;
    const button = target.closest<HTMLButtonElement>("[data-edit-step]");
    if (!button) return;
    setStep(Number(button.dataset.editStep));
  });
  stopsList.addEventListener("click", (event) => {
    const target = event.target as HTMLElement;
    if (target.matches("[data-remove-stop]")) {
      target.closest("[data-stop-card]")?.remove();
      refreshSummary();
      updateSubmitButtonState();
    }
  });
  stopsList.addEventListener("change", (event) => {
    const target = event.target as HTMLElement;
    const card = target.closest<HTMLElement>("[data-stop-card]");
    if (!card) return;
    if (target.matches("[data-stop-time-window]")) {
      const specificTimeField = card.querySelector<HTMLElement>(".specific-time-field");
      if (specificTimeField) specificTimeField.hidden = (target as HTMLSelectElement).value !== "Specific time";
    }
    if (target.matches("[data-stop-type-select]")) {
      const typeField = card.querySelector<HTMLInputElement>('[data-stop-field="stop_type"]');
      if (typeField) typeField.value = (target as HTMLSelectElement).value;
    }
    if (target.matches("[data-method-select]")) {
      const methodName = (target as HTMLSelectElement).dataset.stopMethod;
      const detailField = methodName ? card.querySelector<HTMLElement>(`[data-method-detail="${methodName}"]`)?.closest<HTMLElement>(".method-detail-field") : null;
      if (detailField) detailField.hidden = (target as HTMLSelectElement).value !== "Other / Not sure";
    }
    syncStopDerivedFields(card);
    refreshSummary();
  });
  stopsList.addEventListener("input", (event) => {
    const target = event.target as HTMLElement;
    if (!target.matches("[data-stop-date], [data-stop-specific-time], [data-method-detail]")) return;
    const card = target.closest<HTMLElement>("[data-stop-card]");
    if (!card) return;
    syncStopDerivedFields(card);
    refreshSummary();
    updateSubmitButtonState();
  });
  cargoItemsList.addEventListener("click", (event) => {
    const target = event.target as HTMLElement;
    if (target.matches("[data-remove-cargo]")) {
      target.closest("[data-cargo-card]")?.remove();
      refreshDynamicQuestions();
      refreshSummary();
      updateSubmitButtonState();
    }
  });

  addStop("collection", "Collection stop", false);
  addStop("delivery", "Delivery stop", false);
  addCargoItem();
  setStep(0);
}

type QuoteQueueViewKey = "needs_review" | "approved" | "sent" | "accepted" | "declined" | "archived" | "all";

const quoteQueueViews: Array<{ key: QuoteQueueViewKey; label: string; matches: (request: QuoteRequest) => boolean }> = [
  { key: "needs_review", label: "Needs Review", matches: (request) => ["rfq_submitted", "client_submitted", "admin_review", "adjusted"].includes(request.status) },
  { key: "approved", label: "Approved", matches: (request) => request.status === "approved" },
  { key: "sent", label: "Sent", matches: (request) => request.status === "sent_to_client" },
  { key: "accepted", label: "Accepted", matches: (request) => Boolean(request.transportJob) || ["client_accepted", "converted_to_load"].includes(request.status) },
  { key: "declined", label: "Declined / Review", matches: (request) => request.status === "client_declined" },
  { key: "archived", label: "Archived", matches: (request) => request.status === "expired" },
  { key: "all", label: "All", matches: () => true }
];

function quoteQueueViewFromStatus(status: string | null): QuoteQueueViewKey {
  if (!status) return "needs_review";
  if (["rfq_submitted", "client_submitted", "admin_review", "adjusted", "needs_review"].includes(status)) return "needs_review";
  if (status === "approved") return "approved";
  if (status === "sent_to_client" || status === "sent") return "sent";
  if (["client_accepted", "converted_to_load", "accepted"].includes(status)) return "accepted";
  if (status === "client_declined" || status === "declined") return "declined";
  if (status === "expired" || status === "archived") return "archived";
  if (status === "all") return "all";
  return "needs_review";
}

function shortAddress(address: string): string {
  const [primary] = address.split(",").map((part) => part.trim()).filter(Boolean);
  return primary || "Pending";
}

function quoteShortRoute(request: QuoteRequest): string {
  return `${shortAddress(request.collectionAddress)} -> ${shortAddress(request.deliveryAddress)}`;
}

function quoteTotalWeight(request: QuoteRequest): number {
  return request.items?.length
    ? request.items.reduce((sum, item) => sum + itemTotalWeightKg(item), 0)
    : (request.quantity || 1) * (request.weight ?? 0);
}

function quoteVehicleLabel(request: QuoteRequest): string {
  return request.vehicleRecommendation?.override_vehicle_type
    ?? request.vehicleRecommendation?.recommended_vehicle_type
    ?? request.suggestedVehicle
    ?? "Vehicle review";
}

function quoteSearchText(request: QuoteRequest): string {
  return [
    request.companyName,
    request.contactPerson,
    request.publicReference,
    request.id,
    request.collectionAddress,
    request.deliveryAddress,
    statusLabels[request.status],
    quoteShortRoute(request)
  ].filter(Boolean).join(" ").toLowerCase();
}

function renderQuoteQueue(requests: QuoteRequest[], activeView: QuoteQueueViewKey, searchTerm = ""): string {
  const counts = Object.fromEntries(quoteQueueViews.map((view) => [view.key, requests.filter(view.matches).length])) as Record<QuoteQueueViewKey, number>;

  return `
    <div class="quote-toolbar">
      <div class="filter-tabs" role="tablist" aria-label="Quote filters">
        ${quoteQueueViews.map((view) => `
          <button type="button" class="filter-chip ${view.key === activeView ? "active" : ""}" data-quote-filter="${view.key}" role="tab" aria-selected="${view.key === activeView}">
            ${escapeHtml(view.label)} <span>${counts[view.key]}</span>
          </button>
        `).join("")}
      </div>
      <label class="quote-search">Search quotes
        <input data-quote-search value="${escapeHtml(searchTerm)}" placeholder="Customer, TTAQ reference, collection, destination" />
      </label>
    </div>
    <div class="quote-list compact-quote-list" data-quote-results>${renderQuoteResults(requests, activeView, searchTerm)}</div>
  `;
}

function renderQuoteResults(requests: QuoteRequest[], activeView: QuoteQueueViewKey, searchTerm = ""): string {
  const selectedView = quoteQueueViews.find((view) => view.key === activeView) ?? quoteQueueViews[0];
  const normalizedSearch = searchTerm.trim().toLowerCase();
  const scopedRequests = requests
    .filter((request) => selectedView.matches(request))
    .filter((request) => !normalizedSearch || quoteSearchText(request).includes(normalizedSearch))
    .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  return scopedRequests.length
    ? scopedRequests.map(renderCompactQuoteCard).join("")
    : `<div class="empty-state"><strong>No quotes found</strong><span>${normalizedSearch ? "Try another customer, reference, collection, or destination." : "This queue is clear. Older records are still available through the other filters."}</span></div>`;
}

function renderCompactQuoteCard(request: QuoteRequest): string {
  const totalWeight = quoteTotalWeight(request);
  const quotePrice = request.quotePrice ?? request.pricingCalculation?.recommended_selling_price ?? null;
  return `
    <article class="quote-row compact-quote-row">
      <div class="quote-main">
        <div class="quote-title-line">
          <strong>${escapeHtml(request.companyName || "Customer pending")}</strong>
          <span class="badge">${escapeHtml(statusLabels[request.status] ?? request.status)}</span>
        </div>
        <span class="quote-reference">${escapeHtml(request.publicReference ?? request.id)}</span>
        <span class="quote-route">${escapeHtml(quoteShortRoute(request))}</span>
        <small>${escapeHtml(formatDateTime(request.createdAt))}</small>
      </div>
      <div class="quote-meta">
        <span>${formatKg(totalWeight)} kg</span>
        <span>${money(quotePrice)}</span>
        <span>${escapeHtml(quoteVehicleLabel(request))}</span>
      </div>
      <a class="button small primary" href="./quote-review.html?id=${request.id}">Open Quote</a>
    </article>
  `;
}

async function initQuoteReview(): Promise<void> {
  const params = new URLSearchParams(window.location.search);
  const id = params.get("id") ?? null;
  const statusFilter = params.get("status");
  let request = getRequest(id);
  if (id && isSupabaseConfigured) {
    try {
      const record = await loadAdminQuoteRequest(id);
      request = record ? requestFromRecord(record) : undefined;
    } catch (error) {
      const detail = document.querySelector<HTMLElement>("#quoteDetail");
      if (detail) detail.innerHTML = `<p class="muted">RFQ could not load: ${escapeHtml(friendlyError(error))}</p>`;
    }
  }
  const detail = document.querySelector<HTMLElement>("#quoteDetail");
  const form = document.querySelector<HTMLFormElement>("#reviewForm");
  const output = document.querySelector<HTMLElement>("#reviewOutput");
  if (!detail || !form || !output) return;

  if (!request) {
    if (isSupabaseConfigured) {
      try {
        const records = await loadAdminQuoteRequests();
        const requests = records.map(requestFromRecord);
        let activeView = quoteQueueViewFromStatus(statusFilter);
        let searchTerm = "";
        const renderQueue = () => {
          detail.innerHTML = renderQuoteQueue(requests, activeView, searchTerm);
          detail.querySelectorAll<HTMLButtonElement>("[data-quote-filter]").forEach((button) => {
            button.addEventListener("click", () => {
              activeView = button.dataset.quoteFilter as QuoteQueueViewKey;
              searchTerm = detail.querySelector<HTMLInputElement>("[data-quote-search]")?.value ?? "";
              renderQueue();
            });
          });
          detail.querySelector<HTMLInputElement>("[data-quote-search]")?.addEventListener("input", (event) => {
            searchTerm = (event.currentTarget as HTMLInputElement).value;
            const results = detail.querySelector<HTMLElement>("[data-quote-results]");
            if (results) results.innerHTML = renderQuoteResults(requests, activeView, searchTerm);
          });
        };
        renderQueue();
      } catch (error) {
        detail.innerHTML = `<p class="muted">RFQ queue could not load: ${escapeHtml(friendlyError(error))}</p>`;
      }
    } else {
      detail.innerHTML = `<p class="muted">Connect Supabase to load the live RFQ queue.</p>`;
    }
    form.hidden = true;
    return;
  }

  const reviewRequest = request;
  const reviewOutput = output;
  const acceptedStatuses: QuoteStatus[] = ["client_accepted", "converted_to_load"];
  const isAcceptedQuote = acceptedStatuses.includes(reviewRequest.status);
  const isOpenSentQuote = reviewRequest.status === "sent_to_client";
  const isDeclinedQuote = reviewRequest.status === "client_declined";
  const canEditReviewPrice = !isAcceptedQuote && !isOpenSentQuote;
  const canArchiveReview = !isAcceptedQuote && !isOpenSentQuote;
  const stops = request.stops ?? [];
  const items = request.items ?? [];
  const dynamicAnswers = request.dynamicAnswers ?? [];

  detail.innerHTML = `
    <div class="detail-grid">
      <section class="summary-block quote-review-summary">
        <div class="card-heading"><h2>RFQ Summary</h2><span>${escapeHtml(statusLabels[request.status] ?? request.status)}</span></div>
        <div class="grid three">
          <p><strong>Reference</strong><span>${escapeHtml(request.publicReference ?? request.id)}</span></p>
          <p><strong>Customer</strong><span>${escapeHtml(request.companyName)}</span></p>
          <p><strong>Contact</strong><span>${escapeHtml(request.contactPerson)} - ${escapeHtml(request.email)}</span></p>
          <p><strong>Total weight</strong><span>${formatKg(quoteTotalWeight(request))} kg</span></p>
          <p><strong>Accepted load</strong><span>${request.transportJob ? `${escapeHtml(request.transportJob.job_number)}` : "Created after customer acceptance"}</span></p>
        </div>
      </section>
      <div class="summary-block">
        <h3>Stops</h3>
        ${
          stops.length
            ? stops.map((stop) => `<p>${stop.stop_order}. <strong>${escapeHtml(stop.stop_type)}</strong> - ${escapeHtml(stop.address)}${stop.date_time_window ? ` (${escapeHtml(stop.date_time_window)})` : ""}</p>`).join("")
            : `<p>${escapeHtml(request.collectionAddress)} to ${escapeHtml(request.deliveryAddress)}</p>`
        }
      </div>
      <div class="summary-block">
        <h3>Cargo items</h3>
        ${
          items.length
            ? items.map((item) => `<p><strong>${escapeHtml(item.description ?? "Cargo item")}</strong> - ${item.quantity} item(s), ${item.length_m ?? 0}m x ${item.width_m ?? 0}m x ${item.height_m ?? 0}m, ${escapeHtml(cargoWeightLabel(item))}, ${escapeHtml((item.cargo_category ?? "general_freight").replace("_", " "))}</p>`).join("")
            : `<p>${escapeHtml(request.quantity.toString())} x ${escapeHtml(request.cargoType)} - ${request.length}m x ${request.width}m x ${request.height}m, ${request.weight}kg each</p>`
        }
      </div>
      ${dynamicAnswers.length ? `<div class="summary-block"><h3>Additional RFQ details</h3>${dynamicAnswers.map((answer) => `<p><strong>${escapeHtml(answer.question_key.replaceAll("_", " "))}</strong>: ${escapeHtml(answer.answer_value || "Not supplied")}</p>`).join("")}</div>` : ""}
      ${renderRouteIntelligenceCard(request)}
      ${renderVehicleIntelligenceCard(request)}
      ${renderPricingSummaryCard(request)}
      <p><strong>Special requirements</strong><span>${escapeHtml(request.specialRequirements || "None captured")}</span></p>
    </div>
  `;
  void hydrateRouteMapPreview(request);
  void hydrateEquipmentOverrideControls(request, canEditReviewPrice, output);

  form.quotePrice.value = request.quotePrice?.toString() ?? "";
  form.adminNotes.value = request.adminNotes;
  form.querySelector<HTMLButtonElement>("button[type='submit']")?.toggleAttribute("disabled", !canEditReviewPrice);
  document.querySelector<HTMLButtonElement>("#markSentButton")?.toggleAttribute("disabled", isAcceptedQuote || isOpenSentQuote);
  document.querySelector<HTMLButtonElement>("#archiveQuoteButton")?.toggleAttribute("disabled", !canArchiveReview);
  if (isDeclinedQuote) {
    output.innerHTML = `<strong>Review required.</strong><span>This quote was declined. Revise pricing or notes, then resend a new version, or archive it.</span>`;
  } else if (isOpenSentQuote) {
    output.innerHTML = `<strong>Quote already sent.</strong><span>Customer-visible sent versions are locked. Wait for accept/decline before revising.</span>`;
  } else if (isAcceptedQuote) {
    output.innerHTML = `<strong>Accepted quote locked.</strong><span>Accepted quotes create accepted loads and cannot be archived or revised here.</span>`;
  }

  document.querySelector<HTMLButtonElement>("#googleRouteEstimateButton")?.addEventListener("click", async () => {
    const routeAddresses = routeAddressesForQuote(request);
    try {
      const estimate = await estimateRouteWithGoogleMaps(routeAddresses);
      const distanceInput = document.querySelector<HTMLInputElement>("[name='routeDistanceKm']");
      const durationInput = document.querySelector<HTMLInputElement>("[name='routeDurationHours']");
      if (distanceInput) distanceInput.value = String(estimate.distanceKm);
      if (durationInput) durationInput.value = String(estimate.durationHours);

      if (!isSupabaseConfigured) {
        output.innerHTML = `<strong>Google route estimated.</strong><span>${estimate.distanceKm} km / ${estimate.durationHours} hours. Connect Supabase to store the estimate and regenerate pricing.</span>`;
        return;
      }

      await updateRouteEstimateGoogle({
        quoteRequestId: request.id,
        distanceKm: estimate.distanceKm,
        durationHours: estimate.durationHours,
        googleMapsUrl: estimate.googleMapsUrl,
        providerResponse: estimate.providerResponse,
        providerStatus: "success"
      });
      output.innerHTML = `<strong>Google route saved.</strong><span>Route source stored as Google Maps and pricing was regenerated with ${estimate.distanceKm} km / ${estimate.durationHours} hours.</span>`;
      window.setTimeout(() => window.location.reload(), 900);
    } catch (error) {
      output.innerHTML = `<strong>Google route unavailable.</strong><span>${escapeHtml(friendlyError(error, "Google Maps route estimation failed. Use the manual distance and duration fallback."))}</span>`;
    }
  });

  document.querySelector<HTMLButtonElement>("#regeneratePricingButton")?.addEventListener("click", async () => {
    const distanceKm = Number(document.querySelector<HTMLInputElement>("[name='routeDistanceKm']")?.value ?? 0);
    const durationHours = Number(document.querySelector<HTMLInputElement>("[name='routeDurationHours']")?.value ?? 0);
    const reason = document.querySelector<HTMLInputElement>("[name='routeOverrideReason']")?.value.trim() ?? "";

    if (!Number.isFinite(distanceKm) || !Number.isFinite(durationHours)) {
      output.innerHTML = `<strong>Route update failed.</strong><span>Enter valid distance and duration values.</span>`;
      return;
    }

    if (isSupabaseConfigured) {
      try {
        await updateRouteEstimateManual({
          quoteRequestId: request.id,
          distanceKm,
          durationHours,
          reason
        });
        output.innerHTML = `<strong>Route estimate saved.</strong><span>Pricing was regenerated with ${distanceKm} km and ${durationHours} hours.</span>`;
        window.setTimeout(() => window.location.reload(), 900);
      } catch (error) {
        output.innerHTML = `<strong>Route update failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
      }
      return;
    }

    output.innerHTML = `<strong>Route estimate updated locally.</strong><span>Connect Supabase to store route estimates and regenerate pricing.</span>`;
  });

  const publicQuoteViewLink = `${window.location.origin}${window.location.pathname.replace("quote-review.html", "quote-view.html")}?ref=${encodeURIComponent(reviewRequest.publicReference ?? reviewRequest.id)}`;
  let preparedQuoteDocument: QuoteDocumentRecord | null = reviewRequest.quoteDocuments?.[0] ?? null;

  async function prepareQuoteDocument(actionLabel: string): Promise<QuoteDocumentRecord | null> {
    if (isSupabaseConfigured) {
      try {
        const generated = await generateQuotePdf(reviewRequest.id);
        const documentRecord = await loadInternalQuoteDocument({ quoteDocumentId: generated.quoteDocumentId });
        if (!documentRecord) throw new Error("Quote document was generated but could not be loaded.");
        preparedQuoteDocument = { ...documentRecord, pdf_storage_path: generated.storagePath, generated_at: new Date().toISOString() };
        reviewOutput.innerHTML = `<strong>${escapeHtml(actionLabel)} complete.</strong><span>Customer-safe PDF generated server-side and stored privately.</span><small><a href="${escapeHtml(generated.signedUrl)}" target="_blank" rel="noopener noreferrer">Open signed PDF</a></small><small>${escapeHtml(publicQuoteViewLink)}</small>`;
        return preparedQuoteDocument;
      } catch (error) {
        reviewOutput.innerHTML = `<strong>${escapeHtml(actionLabel)} failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
      }
      return null;
    }
    reviewOutput.innerHTML = `<strong>${escapeHtml(actionLabel)} unavailable.</strong><span>Connect Supabase to generate versioned customer quote documents.</span>`;
    return null;
  }

  document.querySelector<HTMLButtonElement>("#generateQuoteButton")?.addEventListener("click", () => {
    void prepareQuoteDocument("Generate Quote");
  });

  document.querySelector<HTMLButtonElement>("#regenerateQuoteButton")?.addEventListener("click", () => {
    void prepareQuoteDocument("Regenerate Quote");
  });

  document.querySelector<HTMLButtonElement>("#previewQuoteButton")?.addEventListener("click", () => {
    output.innerHTML = `<strong>Customer quote preview.</strong><span>Open the public quote view after generating the document.</span><small>${escapeHtml(publicQuoteViewLink)}</small>`;
  });

  document.querySelector<HTMLButtonElement>("#downloadPdfButton")?.addEventListener("click", async () => {
    if (!isSupabaseConfigured) {
      output.innerHTML = `<strong>PDF unavailable.</strong><span>Connect Supabase to generate the customer-safe quote document first.</span>`;
      return;
    }
    const documentRecord = preparedQuoteDocument ?? await loadInternalQuoteDocument({ quoteRequestId: reviewRequest.id });
    if (!documentRecord) {
      output.innerHTML = `<strong>No quote document yet.</strong><span>Generate Quote before downloading the customer-safe PDF.</span>`;
      return;
    }
    try {
      const download = documentRecord.pdf_storage_path
        ? await getInternalDocumentUrl("quote-documents", documentRecord.pdf_storage_path)
        : await generateQuotePdf(reviewRequest.id);
      window.open(download.signedUrl, "_blank", "noopener,noreferrer");
      output.innerHTML = `<strong>Signed quote PDF opened.</strong><span>The link is temporary and customer-safe.</span>`;
    } catch (error) {
      output.innerHTML = `<strong>PDF download failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
    }
  });

  document.querySelector<HTMLButtonElement>("#archiveQuoteButton")?.addEventListener("click", async () => {
    const note = formValue(new FormData(form), "adminNotes") || "Archived from quote review";
    if (!canArchiveReview) {
      output.innerHTML = `<strong>Archive blocked.</strong><span>${isAcceptedQuote ? "Accepted quotes are protected because they create accepted loads." : "Sent customer quotes are locked until the customer responds."}</span>`;
      return;
    }
    if (isSupabaseConfigured) {
      try {
        await archiveQuoteRequest(reviewRequest.id, note);
        output.innerHTML = `<strong>Quote archived.</strong><span>The request moved out of active quote queues.</span>`;
        window.setTimeout(() => window.location.href = "./quote-review.html", 900);
      } catch (error) {
        output.innerHTML = `<strong>Archive failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
      }
      return;
    }
    updateStatus(reviewRequest.id, "expired");
    output.innerHTML = `<strong>Quote archived.</strong><span>The local request moved out of active quote queues.</span>`;
  });

  document.querySelector<HTMLButtonElement>("#sendQuoteEmailButton")?.addEventListener("click", async () => {
    if (!isSupabaseConfigured) {
      output.innerHTML = `<strong>Email not sent.</strong><span>Connect Supabase before recording quote email status.</span>`;
      return;
    }
    const documentRecord = preparedQuoteDocument ?? await prepareQuoteDocument("Generate Quote");
    if (!documentRecord) return;
    try {
      const result = await sendQuoteEmail({
        quoteDocumentId: documentRecord.id,
        to: reviewRequest.email
      });
      output.innerHTML = result.status === "sent"
        ? `<strong>Quote email sent.</strong><span>${escapeHtml(result.provider)} accepted the message${result.providerMessageId ? ` (${escapeHtml(result.providerMessageId)})` : ""}.</span><small>${escapeHtml(publicQuoteViewLink)}</small>`
        : result.provider === "unconfigured"
          ? `<strong>Quote sent successfully.</strong><span>Email delivery is not configured yet. You can share the customer quote link manually.</span><small>${escapeHtml(publicQuoteViewLink)}</small>`
        : `<strong>Quote email failed.</strong><span>${escapeHtml(result.error ?? "Email provider is not configured or rejected the message.")}</span><small>${escapeHtml(publicQuoteViewLink)}</small>`;
    } catch (error) {
      output.innerHTML = `<strong>Email status failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
    }
  });

  const convertButton = document.querySelector<HTMLButtonElement>("#convertToJobButton");
  if (convertButton) {
    convertButton.textContent = "Open Accepted Loads";
    convertButton.addEventListener("click", () => {
      window.location.href = "./accepted-loads.html";
    });
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!canEditReviewPrice) {
      output.innerHTML = `<strong>Approval blocked.</strong><span>${isAcceptedQuote ? "Accepted quotes cannot be revised here." : "Already-sent quotes are locked until the customer responds."}</span>`;
      return;
    }
    const data = new FormData(form);
    const adjustedPrice = numberValue(data, "quotePrice");
    const adminNotes = formValue(data, "adminNotes");
    const overrideSellingPrice = numberValue(data, "overrideSellingPrice");
    const overrideReason = formValue(data, "overrideReason");
    const componentOverrideLine = formValue(data, "componentOverrideLine");
    const componentOverrideAmount = numberValue(data, "componentOverrideAmount");
    const componentOverrideReason = formValue(data, "componentOverrideReason");
    if (isSupabaseConfigured) {
      try {
        if (request.pricingCalculation && componentOverrideLine && componentOverrideReason) {
          await recordPricingComponentOverride({
            quoteRequestId: request.id,
            pricingCalculationId: request.pricingCalculation.id,
            lineKey: componentOverrideLine,
            overrideAmount: componentOverrideAmount,
            overrideReason: componentOverrideReason
          });
        }
        if (request.pricingCalculation && overrideReason) {
          await recordPricingAdjustment({
            quoteRequestId: request.id,
            pricingCalculationId: request.pricingCalculation.id,
            adjustedSellingPrice: overrideSellingPrice,
            adjustmentReason: overrideReason
          });
        }
        await updateAdminQuote(request.id, {
          adminNotes,
          adjustedPrice: overrideReason ? overrideSellingPrice : adjustedPrice,
          status: "approved"
        });
        output.innerHTML = `<strong>Quote approved.</strong><span>Owner/manager permission is enforced by Supabase RPC.</span>`;
      } catch (error) {
        output.innerHTML = `<strong>Approval failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
      }
      return;
    }
    const requests = readRequests();
    const current = requests.find((item) => item.id === request.id);
    if (!current) return;
    current.quotePrice = adjustedPrice;
    current.adminNotes = adminNotes;
    current.status = "approved";
    writeRequests(requests);
    output.innerHTML = `<strong>Quote approved.</strong><span>Approval must be enforced by owner/manager role when auth is wired.</span>`;
  });

  document.querySelector<HTMLButtonElement>("#markSentButton")?.addEventListener("click", async () => {
    if (isAcceptedQuote || isOpenSentQuote) {
      output.innerHTML = `<strong>Send blocked.</strong><span>${isAcceptedQuote ? "Accepted quotes already created an accepted load." : "This quote has already been sent to the customer."}</span>`;
      return;
    }
    const data = new FormData(form);
    const adjustedPrice = numberValue(data, "quotePrice");
    const adminNotes = formValue(data, "adminNotes");
    const overrideSellingPrice = numberValue(data, "overrideSellingPrice");
    const overrideReason = formValue(data, "overrideReason");
    const componentOverrideLine = formValue(data, "componentOverrideLine");
    const componentOverrideAmount = numberValue(data, "componentOverrideAmount");
    const componentOverrideReason = formValue(data, "componentOverrideReason");
    if (isSupabaseConfigured) {
      try {
        if (request.pricingCalculation && componentOverrideLine && componentOverrideReason) {
          await recordPricingComponentOverride({
            quoteRequestId: request.id,
            pricingCalculationId: request.pricingCalculation.id,
            lineKey: componentOverrideLine,
            overrideAmount: componentOverrideAmount,
            overrideReason: componentOverrideReason
          });
        }
        if (request.pricingCalculation && overrideReason) {
          await recordPricingAdjustment({
            quoteRequestId: request.id,
            pricingCalculationId: request.pricingCalculation.id,
            adjustedSellingPrice: overrideSellingPrice,
            adjustmentReason: overrideReason
          });
        }
        await updateAdminQuote(request.id, {
          adminNotes,
          adjustedPrice: overrideReason ? overrideSellingPrice : adjustedPrice,
          status: "sent_to_client"
        });
        const documentRecord = preparedQuoteDocument ?? await prepareQuoteDocument("Generate Quote");
        if (!documentRecord) throw new Error("Quote document could not be generated before sending.");
        const result = await sendQuoteEmail({
          quoteDocumentId: documentRecord.id,
          to: request.email
        });
        const quoteLink = publicQuoteViewLink;
        const email = buildClientQuoteEmail(request, quoteLink);
        output.innerHTML = result.status === "sent"
          ? `<strong>Marked as sent.</strong><span>${escapeHtml(email.subject)} sent through ${escapeHtml(result.provider)}.</span><small>${escapeHtml(quoteLink)}</small>`
          : result.provider === "unconfigured"
            ? `<strong>Quote sent successfully.</strong><span>Email delivery is not configured yet. You can share the customer quote link manually.</span><small>${escapeHtml(quoteLink)}</small>`
          : `<strong>Marked as sent, email failed.</strong><span>${escapeHtml(result.error ?? "Email provider is not configured or rejected the message.")}</span><small>${escapeHtml(quoteLink)}</small>`;
      } catch (error) {
        output.innerHTML = `<strong>Send failed.</strong><span>${escapeHtml(friendlyError(error))}</span>`;
      }
      return;
    }
    updateStatus(request.id, "sent_to_client");
    const refreshed = getRequest(request.id);
    const quoteLink = publicQuoteViewLink;
    const email = refreshed ? buildClientQuoteEmail(refreshed, quoteLink) : null;
    output.innerHTML = `<strong>Marked as sent.</strong><span>${email ? escapeHtml(email.subject) : "Client email event recorded."}</span>`;
  });
}

async function initQuoteResponse(): Promise<void> {
  const params = new URLSearchParams(window.location.search);
  const token = params.get("token");
  const reference = params.get("ref");
  const id = params.get("id") ?? readRequests().find((request) => request.status === "sent_to_client")?.id ?? readRequests()[0]?.id ?? null;
  let request = getRequest(id);
  if (isSupabaseConfigured) {
    try {
      const record = await loadPublicQuoteResponse(token, reference);
      request = record ? requestFromRecord(record) : undefined;
    } catch (error) {
      const card = document.querySelector<HTMLElement>("#responseCard");
      if (card) card.innerHTML = `<p class="muted">Quote could not load: ${escapeHtml(friendlyError(error, "This quote link could not be opened. Please check the reference or ask Time Trucking for a fresh link."))}</p>`;
    }
  }
  const card = document.querySelector<HTMLElement>("#responseCard");
  const output = document.querySelector<HTMLElement>("#responseOutput");
  if (!card || !output) return;

  if (!request) {
    card.innerHTML = `<p class="muted">No quote is available yet.</p>`;
    return;
  }

  card.innerHTML = `
    <h2>${escapeHtml(request.companyName)}</h2>
    <p>${escapeHtml(request.collectionAddress)} to ${escapeHtml(request.deliveryAddress)}</p>
    <p><strong>Suggested transport:</strong> ${escapeHtml(request.suggestedVehicle)} / ${escapeHtml(request.suggestedTrailer)}</p>
    <p><strong>Quote price:</strong> ${currency(request.quotePrice)}</p>
    <p><strong>Status:</strong> ${statusLabels[request.status]}</p>
    <div class="button-row">
      <button class="primary" data-decision="client_accepted">Accept quote</button>
      <button data-decision="client_declined">Decline quote</button>
    </div>
  `;

  card.querySelectorAll<HTMLButtonElement>("[data-decision]").forEach((button) => {
    button.addEventListener("click", async () => {
      const decision = button.dataset.decision as Extract<QuoteStatus, "client_accepted" | "client_declined">;
      if (isSupabaseConfigured) {
        try {
          await submitPublicQuoteDecision(token, reference, decision);
          const refreshed = { ...request, status: decision };
          const email = buildAdminDecisionEmail(refreshed);
          output.innerHTML = `<strong>Response saved.</strong><span>${escapeHtml(email.subject)} notification event recorded.</span>`;
        } catch (error) {
          output.innerHTML = `<strong>Response failed.</strong><span>${escapeHtml(friendlyError(error, "Your response could not be saved. Please try again or contact Time Trucking."))}</span>`;
        }
        return;
      }
      updateStatus(request.id, decision);
      const refreshed = getRequest(request.id);
      const email = refreshed ? buildAdminDecisionEmail(refreshed) : null;
      output.innerHTML = `<strong>Response saved.</strong><span>${email ? escapeHtml(email.subject) : "Admin notification event recorded."}</span>`;
    });
  });
}

async function initQuoteView(): Promise<void> {
  const card = document.querySelector<HTMLElement>("#quoteViewCard");
  const output = document.querySelector<HTMLElement>("#quoteViewOutput");
  if (!card || !output) return;

  const params = new URLSearchParams(window.location.search);
  const token = params.get("token");
  const reference = params.get("ref");

  if (!isSupabaseConfigured) {
    card.innerHTML = `<p class="muted">Connect Supabase to load customer quote documents. This page will display only customer-safe quote details.</p>`;
    return;
  }

  let documentRecord: PublicQuoteDocumentRecord | null = null;
  try {
    documentRecord = await loadPublicQuoteDocument(token, reference);
  } catch (error) {
    card.innerHTML = `<p class="muted">Quote document could not load: ${escapeHtml(friendlyError(error, "This quote document is not available. Please contact Time Trucking for assistance."))}</p>`;
    return;
  }

  if (!documentRecord) {
    card.innerHTML = `<p class="muted">No customer quote document is available for this link.</p>`;
    return;
  }

  card.innerHTML = renderCustomerQuoteDocument(documentRecord);

  card.querySelector<HTMLButtonElement>("#customerDownloadPdfButton")?.addEventListener("click", async () => {
    try {
      const download = await getPublicQuotePdfUrl(token, reference);
      window.open(download.signedUrl, "_blank", "noopener,noreferrer");
      output.innerHTML = `<strong>PDF opened.</strong><span>This secure download link is temporary.</span>`;
    } catch (error) {
      output.innerHTML = `<strong>PDF unavailable.</strong><span>${escapeHtml(friendlyError(error, "The PDF has not been generated yet. Please contact Time Trucking."))}</span>`;
    }
  });

  card.querySelectorAll<HTMLButtonElement>("[data-quote-decision]").forEach((button) => {
    button.addEventListener("click", async () => {
      const decision = button.dataset.quoteDecision as Extract<QuoteStatus, "client_accepted" | "client_declined">;
      try {
        await submitPublicQuoteDecision(token, reference, decision);
        output.innerHTML = decision === "client_accepted"
          ? `<strong>Quote accepted.</strong><span>Time Trucking has been notified and an accepted load/order number will be created internally.</span>`
          : `<strong>Response saved.</strong><span>Time Trucking has been notified.</span>`;
      } catch (error) {
        output.innerHTML = `<strong>Response failed.</strong><span>${escapeHtml(friendlyError(error, "Your response could not be saved. Please try again or contact Time Trucking."))}</span>`;
      }
    });
  });

  card.querySelector<HTMLButtonElement>("#revisionRequestButton")?.addEventListener("click", async () => {
    const label = card.querySelector<HTMLElement>("#revisionMessageLabel");
    const messageInput = card.querySelector<HTMLTextAreaElement>("#revisionMessage");
    if (label?.hidden) {
      label.hidden = false;
      messageInput?.focus();
      output.innerHTML = `<strong>Revision request.</strong><span>Add a note, then press Request revision again.</span>`;
      return;
    }

    const message = messageInput?.value.trim() ?? "";
    if (!message) {
      output.innerHTML = `<strong>Revision request needs detail.</strong><span>Please add a short note for Time Trucking.</span>`;
      return;
    }

    try {
      await requestQuoteRevision(token, reference, message);
      output.innerHTML = `<strong>Revision requested.</strong><span>Time Trucking will review the requested change. Email delivery requires a configured mail provider.</span>`;
    } catch (error) {
      output.innerHTML = `<strong>Revision request failed.</strong><span>${escapeHtml(friendlyError(error, "Your revision request could not be saved. Please try again or contact Time Trucking."))}</span>`;
    }
  });
}

async function initCustomerPortal(): Promise<void> {
  const card = document.querySelector<HTMLElement>("#customerPortalCard");
  const output = document.querySelector<HTMLElement>("#customerPortalOutput");
  if (!card || !output) return;

  const params = new URLSearchParams(window.location.search);
  const token = params.get("token");
  const reference = params.get("ref");

  if (!isSupabaseConfigured) {
    card.innerHTML = `<p class="muted">Connect Supabase to load the customer portal.</p>`;
    return;
  }

  try {
    const portal = await loadCustomerPortal(token, reference);
    card.innerHTML = portal ? renderCustomerPortal(portal) : `<p class="muted">No customer portal data is available for this secure link.</p>`;
  } catch (error) {
    card.innerHTML = `<p class="muted">Customer portal could not load: ${escapeHtml(friendlyError(error, "This customer portal link could not be opened. Please check the reference or ask Time Trucking for help."))}</p>`;
  }
}

async function bootstrap(): Promise<void> {
  await initLogin();

  if (!(await requireInternalAccess())) {
    if (!isInternalPage()) {
      initClientRfq();
      void initQuoteResponse();
      void initQuoteView();
      void initCustomerPortal();
    }
    return;
  }

  renderShellActiveNav();
  void initDashboard();
  void initJobs();
  void initCustomers();
  void initAdminSettings();
  void initUsersDashboard();
  initPricingSettings();
  initCreateLink();
  initClientRfq();
  void initQuoteReview();
  void initQuoteResponse();
  void initQuoteView();
  void initCustomerPortal();
}

void bootstrap();
