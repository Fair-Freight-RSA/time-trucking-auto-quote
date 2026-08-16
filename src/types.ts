export type QuoteStatus =
  | "draft"
  | "rfq_submitted"
  | "client_submitted"
  | "admin_review"
  | "adjusted"
  | "approved"
  | "sent_to_client"
  | "client_accepted"
  | "client_declined"
  | "expired"
  | "converted_to_load";

export type LoadServiceType = "dedicated" | "part_load";
export type InternalRole = "owner" | "manager" | "staff" | "viewer";
export type InternalUserStatus = "active" | "revoked";
export type StopType = "collection" | "delivery" | "warehouse" | "border" | "other";
export type CargoCategory = "general_freight" | "machinery" | "dangerous_goods" | "refrigerated" | "other";
export type EquipmentSource = "own_fleet" | "subcontractor" | "either";

export interface InternalUser {
  id: string;
  fullName: string;
  email: string;
  role: InternalRole;
  status: InternalUserStatus;
  canViewAllQuotes: boolean;
  canManageRfqs: boolean;
  canApproveQuotes: boolean;
  canAdjustPricing: boolean;
  canManageUsers: boolean;
  invitedBy: string;
  revokedAt: string;
  lastLoginAt: string;
}

export interface InternalUserRecord {
  id: string;
  email: string;
  full_name: string | null;
  role: InternalRole;
  user_status: InternalUserStatus;
  can_view_all_quotes: boolean;
  can_manage_rfqs: boolean;
  can_approve_quotes: boolean;
  can_adjust_pricing: boolean;
  can_manage_pricing_rules: boolean;
  can_manage_users: boolean;
  invited_by?: string | null;
  revoked_at?: string | null;
  created_at?: string | null;
  last_login_at: string | null;
}

export interface QuoteRequest {
  id: string;
  status: QuoteStatus;
  companyName: string;
  contactPerson: string;
  email: string;
  phone: string;
  collectionAddress: string;
  deliveryAddress: string;
  cargoType: string;
  loadDescription: string;
  quantity: number;
  length: number;
  width: number;
  height: number;
  weight: number;
  stackable: boolean;
  loadType: LoadServiceType;
  loadingMethod: string;
  offloadingMethod: string;
  goodsValue: number;
  insurance: boolean;
  collectionDate: string;
  deliveryDate: string;
  specialRequirements: string;
  attachmentNote: string;
  suggestedVehicle: string;
  suggestedTrailer: string;
  adminNotes: string;
  quotePrice: number | null;
  publicReference?: string;
  responseToken?: string;
  stops?: QuoteStopRecord[];
  items?: QuoteItemRecord[];
  dynamicAnswers?: RfqDynamicAnswerRecord[];
  vehicleRecommendation?: VehicleRecommendationRecord;
  transportFlags?: TransportRequirementFlagRecord[];
  routeEstimate?: RouteEstimateRecord;
  routeEstimateStops?: RouteEstimateStopRecord[];
  pricingCalculation?: PricingCalculationRecord;
  pricingBreakdowns?: PricingBreakdownRecord[];
  pricingAdjustments?: PricingAdjustmentRecord[];
  pricingComponentOverrides?: PricingComponentOverrideRecord[];
  quoteDocuments?: QuoteDocumentRecord[];
  transportJob?: TransportJobRecord;
  returnLoadStatus?: string | null;
  returnLoadPricingStatus?: string | null;
  returnLoadNotes?: string | null;
  operationalJourney?: OperationalJourneySummaryRecord | null;
  createdAt: string;
}

export interface QuoteSuggestion {
  suggestedVehicle: string;
  suggestedTrailer: string;
  notes: string;
}

export interface QuoteRequestRecord {
  id: string;
  status: QuoteStatus;
  public_reference: string | null;
  company_name: string;
  contact_person: string;
  email: string;
  phone: string | null;
  collection_address: string;
  delivery_address: string;
  cargo_type: string;
  load_description: string;
  stackable: boolean;
  load_type: LoadServiceType;
  loading_method: string | null;
  offloading_method: string | null;
  goods_value: number | null;
  insurance_required: boolean;
  collection_date: string | null;
  delivery_date: string | null;
  special_requirements: string | null;
  attachment_note: string | null;
  suggestion_notes: string | null;
  admin_notes: string | null;
  adjusted_price: number | null;
  return_load_status?: string | null;
  return_load_pricing_status?: string | null;
  return_load_notes?: string | null;
  commercial_billable_distance_basis?: string | null;
  operational_review_status?: string | null;
  operational_review_notes?: string | null;
  created_at: string;
  quote_items?: QuoteItemRecord[];
  quote_stops?: QuoteStopRecord[];
  rfq_dynamic_answers?: RfqDynamicAnswerRecord[];
  vehicle_recommendations?: VehicleRecommendationRecord[];
  transport_requirement_flags?: TransportRequirementFlagRecord[];
  route_estimates?: RouteEstimateRecord[] | RouteEstimateRecord;
  pricing_calculations?: PricingCalculationRecord[];
  pricing_adjustments?: PricingAdjustmentRecord[];
  pricing_component_overrides?: PricingComponentOverrideRecord[];
  quote_documents?: QuoteDocumentRecord[];
  transport_jobs?: TransportJobRecord[];
}

export interface OperationalJourneyLegRecord {
  leg_key: string;
  leg_label: string;
  origin_address?: string | null;
  destination_address?: string | null;
  distance_km?: number | null;
  duration_hours?: number | null;
  load_status?: string | null;
  backload_status?: string | null;
  toll_status?: string | null;
  route_risk_status?: string | null;
  review_status?: string | null;
  review_reason?: string | null;
}

export interface OperationalJourneySummaryRecord {
  depot_name?: string | null;
  depot_address?: string | null;
  return_load_status?: string | null;
  return_load_pricing_status?: string | null;
  commercial_billable_distance_basis?: string | null;
  operational_review_status?: string | null;
  operational_review_notes?: string | null;
  total_operational_km?: number | null;
  total_operational_duration_hours?: number | null;
  commercial_treatment?: string | null;
  legs?: OperationalJourneyLegRecord[];
}

export interface QuoteItemRecord {
  id: string;
  quote_request_id: string;
  client_item_key?: string | null;
  description: string | null;
  cargo_category?: CargoCategory | null;
  quantity: number;
  length_m: number | null;
  width_m: number | null;
  height_m: number | null;
  weight_kg: number | null;
  stackable?: boolean | null;
  fragile?: boolean | null;
  dangerous_goods?: boolean | null;
  temperature_controlled?: boolean | null;
  cargo_value?: number | null;
  notes?: string | null;
}

export interface PublicQuoteResponseRecord extends QuoteRequestRecord {
  quote_items: QuoteItemRecord[];
}

export interface QuoteStopRecord {
  id: string;
  quote_request_id: string;
  stop_order: number;
  sequence_number?: number;
  stop_type: StopType;
  address: string;
  latitude?: number | null;
  longitude?: number | null;
  place_id?: string | null;
  formatted_address?: string | null;
  contact_name: string | null;
  contact_phone: string | null;
  date_time_window: string | null;
  loading_method: string | null;
  offloading_method: string | null;
  notes: string | null;
}

export interface RfqDynamicAnswerRecord {
  id: string;
  quote_request_id: string;
  cargo_item_id: string | null;
  answer_group: CargoCategory | string;
  question_key: string;
  answer_value: string;
}

export interface VehicleRecommendationRecord {
  id: string;
  quote_request_id: string;
  recommended_vehicle_type: string;
  recommended_trailer_type: string;
  number_of_trucks: number;
  estimated_payload_utilization_percent: number;
  estimated_volume_utilization_percent: number;
  abnormal_load: boolean;
  permit_required: boolean;
  escort_recommended: boolean;
  hazmat_required: boolean;
  refrigeration_required: boolean;
  crane_required: boolean;
  forklift_required: boolean;
  manager_review_required: boolean;
  recommendation_notes: string | null;
  override_vehicle_type: string | null;
  override_trailer_type: string | null;
  override_reason: string | null;
  system_equipment_profile_id?: string | null;
  final_equipment_profile_id?: string | null;
  equipment_source?: EquipmentSource | null;
  equipment_alternatives?: EquipmentAlternativeRecord[] | null;
  estimated_deck_utilization_percent?: number | null;
  recommendation_reasoning?: string[] | null;
  overridden_by?: string | null;
  overridden_at?: string | null;
  reset_to_system_at?: string | null;
  system_number_of_trucks?: number | null;
  system_payload_utilization_percent?: number | null;
  system_volume_utilization_percent?: number | null;
  system_deck_utilization_percent?: number | null;
  equipment_override_history?: EquipmentOverrideHistoryEntry[] | null;
}

export interface EquipmentAlternativeRecord {
  id: string;
  equipment_code?: string;
  display_name: string;
  trailer_body: string;
  units: number;
}

export interface StandardEquipmentProfileRecord {
  id: string;
  equipment_code: string;
  display_name: string;
  vehicle_class: string;
  trailer_body: string;
  payload_capacity_kg: number | null;
  usable_cube_m3: number | null;
  deck_length_m: number | null;
  deck_width_m: number | null;
  usable_deck_area_m2: number | null;
  typical_pallet_capacity: number | null;
  enclosed: boolean;
  open_deck: boolean;
  side_loading: boolean;
  rear_loading: boolean;
  refrigerated: boolean;
  specialist_abnormal: boolean;
  fuel_consumption_l_per_100km: number;
  average_tyre_cost_per_km: number;
  maintenance_cost_per_km: number;
  insurance_cost_per_km: number;
  depreciation_cost_per_km: number;
  vehicle_overhead_per_km: number;
  equipment_source_default: EquipmentSource;
  recommendation_priority: number;
  is_active: boolean;
  toll_class?: number | null;
  toll_class_source?: string | null;
  toll_class_criteria?: Record<string, unknown>;
  toll_class_confirmed_by?: string | null;
  toll_class_confirmed_at?: string | null;
  vehicle_height_m?: number | null;
  axle_count?: number | null;
  suggested_toll_class?: number | null;
  suggested_toll_class_reason?: string | null;
  toll_class_review_required?: boolean | null;
  internal_cost_vehicle_class_key?: string | null;
  internal_cost_profile_mapping_status?: string | null;
  internal_cost_profile_mapping_source?: string | null;
  notes: string | null;
  source_note: string | null;
}

export interface CommercialRateCardRecord {
  id: string;
  pricing_profile_id: string;
  rate_category_key: string;
  display_name: string;
  hazardous: boolean;
  day_rate: number;
  per_km_rate: number;
  axle_count_default: number | null;
  source_note: string | null;
  is_active: boolean;
  updated_at: string;
}

export interface VehicleClassInternalCostComponentRecord {
  component_key: string;
  display_name: string;
  unit_code: string;
  amount: number | null;
  value_status: string;
  source_type: string;
  source_basis: string;
  is_required: boolean;
}

export interface VehicleClassInternalCostProfileRecord {
  profile_id: string;
  vehicle_class_key: string;
  display_name: string;
  effective_from: string;
  effective_to?: string | null;
  profile_status: string;
  source_basis: string;
  notes?: string | null;
  is_active: boolean;
  updated_at: string;
  components: VehicleClassInternalCostComponentRecord[];
  missing_required_components: string[];
}

export interface EquipmentOverrideHistoryEntry {
  action?: string;
  from_equipment?: string;
  to_equipment?: string;
  from_units?: number;
  to_units?: number;
  equipment_source?: EquipmentSource;
  reason?: string;
  user_id?: string;
  timestamp?: string;
}

export interface TransportRequirementFlagRecord {
  id: string;
  quote_request_id: string;
  vehicle_recommendation_id: string | null;
  flag_key: string;
  flag_label: string;
  severity: string;
  flag_notes: string | null;
}

export interface RouteEstimateRecord {
  id: string;
  quote_request_id: string;
  origin_address: string | null;
  destination_address: string | null;
  total_distance_km: number;
  total_duration_hours: number;
  route_notes: string | null;
  provider_name: string;
  confidence_level: string;
  provider_response?: Record<string, unknown>;
  external_route_id: string | null;
  google_maps_url?: string | null;
  provider_status?: string | null;
  provider_error?: string | null;
  estimated_at?: string | null;
  encoded_polyline?: string | null;
  toll_status?: string | null;
  route_risk_status?: string | null;
  origin_latitude: number | null;
  origin_longitude: number | null;
  destination_latitude: number | null;
  destination_longitude: number | null;
  manual_distance_km: number | null;
  manual_duration_hours: number | null;
  manual_override_reason: string | null;
  manually_overridden_by: string | null;
  manually_overridden_at: string | null;
  route_estimate_stops?: RouteEstimateStopRecord[];
}

export interface RouteEstimateStopRecord {
  id: string;
  route_estimate_id: string;
  quote_request_id: string;
  quote_stop_id: string | null;
  stop_order: number;
  stop_type: StopType | string | null;
  address: string;
  latitude: number | null;
  longitude: number | null;
  geocoded: boolean;
  provider_stop_id: string | null;
  place_id?: string | null;
  formatted_address?: string | null;
  created_at: string;
}

export interface PricingCalculationRecord {
  id: string;
  quote_request_id: string;
  vehicle_recommendation_id: string | null;
  pricing_profile_id: string | null;
  calculation_timestamp: string;
  rule_version: string;
  estimated_distance_km: number;
  estimated_duration_hours: number;
  total_weight_kg: number;
  total_volume_m3: number;
  subtotal: number;
  profit_amount: number;
  vat_amount: number;
  grand_total: number;
  recommended_selling_price: number;
  currency: string;
  approved_by: string | null;
  approved_at: string | null;
  calculation_notes: string | null;
  fuel_price_per_litre?: number | null;
  fuel_surcharge_amount?: number | null;
  seasonal_multiplier?: number | null;
  seasonal_amount?: number | null;
  toll_amount?: number | null;
  route_risk_amount?: number | null;
  margin_profile_key?: string | null;
  margin_percent?: number | null;
  dynamic_inputs?: Record<string, unknown>;
  dynamic_outputs?: Record<string, unknown>;
  pricing_source_snapshot?: Record<string, unknown>;
  automation_status?: Record<string, unknown>;
  manager_review_required?: boolean | null;
  pricing_breakdowns?: PricingBreakdownRecord[];
  pricing_calculation_audit_events?: PricingCalculationAuditEventRecord[];
}

export interface PricingBreakdownRecord {
  id: string;
  pricing_calculation_id: string;
  quote_request_id: string;
  line_key: string;
  line_label: string;
  quantity: number;
  unit_rate: number;
  amount: number;
  explanation: string | null;
}

export interface PricingAdjustmentRecord {
  id: string;
  quote_request_id: string;
  pricing_calculation_id: string | null;
  adjusted_selling_price: number;
  previous_selling_price: number | null;
  adjustment_reason: string;
  adjusted_by: string | null;
  calculated_cost_snapshot?: number | null;
  resulting_profit?: number | null;
  resulting_margin_percent?: number | null;
  warning_flags?: string[] | null;
  created_at: string;
}

export interface PricingCalculationAuditEventRecord {
  id: string;
  quote_request_id: string;
  pricing_calculation_id: string | null;
  event_type: string;
  event_payload: Record<string, unknown>;
  created_by: string | null;
  created_at: string;
}

export interface PricingComponentOverrideRecord {
  id: string;
  quote_request_id: string;
  pricing_calculation_id: string | null;
  line_key: string;
  original_amount: number | null;
  override_amount: number;
  override_reason: string;
  overridden_by: string | null;
  created_at: string;
}

export interface QuoteDocumentRecord {
  id: string;
  quote_request_id: string;
  quote_number: string;
  public_reference: string;
  quote_date: string;
  validity_date: string;
  version_number: number;
  status: string;
  final_selling_price: number;
  vat_amount: number;
  currency: string;
  accept_link: string | null;
  decline_link: string | null;
  pdf_placeholder_url: string | null;
  pdf_url?: string | null;
  pdf_storage_path?: string | null;
  generated_at?: string | null;
  sent_at?: string | null;
  email_sent_to?: string | null;
  email_status?: "pending" | "simulated" | "failed" | "sent" | string;
  email_error?: string | null;
  customer_payload: QuoteCustomerPayload;
  document_payload?: Record<string, unknown>;
}

export interface PublicQuoteDocumentRecord {
  quote_document_id: string;
  quote_request_id: string;
  quote_number: string;
  public_reference: string;
  quote_date: string;
  validity_date: string;
  version_number: number;
  status: QuoteStatus;
  final_selling_price: number;
  vat_amount: number;
  currency: string;
  accept_link: string | null;
  decline_link: string | null;
  pdf_placeholder_url: string | null;
  pdf_url: string | null;
  generated_at: string | null;
  customer_payload: QuoteCustomerPayload;
}

export interface QuoteCustomerPayload {
  brand?: {
    brand_name?: string;
    brand_line?: string;
    terms?: string[];
  };
  quote_number?: string;
  public_reference?: string;
  quote_date?: string;
  validity_date?: string;
  version_number?: number;
  customer?: {
    company_name?: string;
    contact_person?: string;
    email?: string;
    phone?: string;
  };
  stops?: Array<Record<string, unknown>>;
  cargo_items?: Array<Record<string, unknown>>;
  route_estimate?: Record<string, unknown>;
  transport?: Record<string, unknown>;
  pricing?: {
    final_selling_price?: number;
    vat_amount?: number;
    currency?: string;
  };
  links?: {
    accept_link?: string;
    decline_link?: string;
    pdf_placeholder_url?: string;
  };
}

export interface CustomerPortalRecord {
  quote_request_id: string;
  public_reference: string | null;
  quote_status: QuoteStatus;
  company_name: string;
  contact_person: string;
  accepted_at: string | null;
  declined_at: string | null;
  quote_documents: Array<Record<string, unknown>>;
}

export interface TransportJobRecord {
  id: string;
  quote_request_id: string;
  quote_document_id: string | null;
  job_number: string;
  public_reference: string;
  job_status: string;
  company_name: string;
  contact_person: string;
  email?: string | null;
  phone?: string | null;
  collection_date?: string | null;
  delivery_date?: string | null;
  route_summary: Record<string, unknown>;
  cargo_summary?: Array<Record<string, unknown>>;
  vehicle_summary: Record<string, unknown>;
  customer_payload?: Record<string, unknown>;
  created_at: string;
  updated_at?: string;
}

export interface InternalSettingsPayload {
  can_update: boolean;
  company_branding: Record<string, unknown>;
  system_settings: SystemSettingRecord[];
  email_templates: EmailTemplatePlaceholderRecord[];
  numbering_sequences: NumberingSequenceSettingRecord[];
  recent_audit_logs: AuditLogRecord[];
}

export interface SystemSettingRecord {
  id?: string;
  setting_key: string;
  setting_category: string;
  display_name: string;
  setting_value: Record<string, unknown>;
  is_restricted: boolean;
  created_at?: string;
  updated_at?: string;
}

export interface EmailTemplatePlaceholderRecord {
  template_key: string;
  template_name: string;
  subject_placeholder: string;
  body_placeholder: string;
  available_variables: string[] | unknown[];
  is_active: boolean;
  created_at?: string;
  updated_at?: string;
}

export interface NumberingSequenceSettingRecord {
  sequence_key: string;
  display_name: string;
  prefix: string;
  next_number: number;
  padding: number;
  suffix: string | null;
  last_generated_at?: string | null;
  created_at?: string;
  updated_at?: string;
}

export interface AuditLogRecord {
  id: string;
  actor_user_id: string | null;
  actor_role: string | null;
  action: string;
  entity_type: string;
  entity_id: string | null;
  old_values: Record<string, unknown>;
  new_values: Record<string, unknown>;
  metadata: Record<string, unknown>;
  created_at: string;
}
