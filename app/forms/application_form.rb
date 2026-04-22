# frozen_string_literal: true

# Form object to handle application validation and state management
# Pure validation layer - persistence is handled by Applications::ApplicationCreator service
class ApplicationForm
  include ActiveModel::Model
  include ActiveModel::Attributes
  include ActiveModel::Validations
  include ParamCasting

  # Application attributes
  attribute :annual_income, :string
  attribute :status, :string, default: 'draft'
  attribute :submission_method, :string, default: 'online'
  attribute :household_size, :integer
  attribute :maryland_resident, :boolean, default: true
  attribute :self_certify_disability, :boolean, default: true

  # File attachments
  attribute :residency_proof
  attribute :income_proof
  attribute :id_proof

  # User attributes (disability flags and address)
  attribute :hearing_disability, :boolean, default: false
  attribute :vision_disability, :boolean, default: false
  attribute :speech_disability, :boolean, default: false
  attribute :mobility_disability, :boolean, default: false
  attribute :cognition_disability, :boolean, default: false
  attribute :locale, :string

  # Address attributes
  attribute :physical_address_1, :string
  attribute :physical_address_2, :string
  attribute :city, :string
  attribute :state, :string
  attribute :zip_code, :string

  # Medical provider attributes
  attribute :medical_provider_name, :string
  attribute :medical_provider_phone, :string
  attribute :medical_provider_fax, :string
  attribute :medical_provider_email, :string

  # Guardian/dependent management
  attribute :user_id, :integer # For dependent applications
  attribute :managing_guardian_id, :integer

  # Alternate contact attributes
  attribute :alternate_contact_name, :string
  attribute :alternate_contact_phone, :string
  attribute :alternate_contact_email, :string
  attribute :alternate_contact_relationship_type, :string

  # Form state
  attribute :is_submission, :boolean, default: false

  # Runtime dependencies (injected)
  attr_accessor :current_user, :application

  # Validations
  validates :current_user, presence: true
  validates :annual_income, presence: true, if: -> { is_submission && income_collection_required? }
  validate :validate_disability_selection, if: :is_submission
  validate :validate_guardian_relationship, if: :for_dependent?
  validate :validate_medical_provider, if: :is_submission

  def initialize(attributes = {})
    @current_user = attributes.delete(:current_user)
    @application = attributes.delete(:application)

    # Handle params-based initialization
    if attributes[:params].present?
      params = attributes.delete(:params)
      super
      populate_from_params(params)
    else
      super
    end
  end

  # Check if this is for a dependent user
  def for_dependent?
    user_id.present? && user_id != current_user&.id
  end

  # Get the applicant user (either current_user or dependent)
  def applicant_user
    @applicant_user ||= determine_applicant_user
  end

  # Get or create the application
  def target_application
    @target_application ||= application || Application.new
  end

  private

  # Cast boolean parameters for the given params hash
  def cast_boolean_params_for(params)
    return if params[:application].blank?

    cast_boolean_fields(params[:application], ParamCasting::APPLICATION_BOOLEAN_FIELDS)
    cast_boolean_fields(params[:application], ParamCasting::USER_DISABILITY_FIELDS)
  end

  def cast_boolean_fields(app_params, fields)
    fields.each do |field|
      field_sym = field.to_sym
      next unless app_params.key?(field_sym)

      value = app_params[field_sym]
      # Handle array workaround for hidden checkbox fields (Rails pattern)
      value = value.last if value.is_a?(Array) && value.size == 2 && value.first.blank?
      app_params[field_sym] = to_boolean(value)
    end
  end

  def populate_from_params(params)
    return if params[:application].blank?

    app_params = params[:application]

    cast_boolean_params_for(params)

    assign_core_attributes(app_params)
    assign_file_attachments(app_params)
    assign_disability_attributes(app_params)

    extract_address_attributes(app_params)
    extract_locale_attribute(params, app_params)
    extract_medical_provider_attributes(params)
    extract_alternate_contact_attributes(app_params)

    self.is_submission = params[:submit_application].present?
  end

  def assign_core_attributes(app_params)
    assign_transformed_attributes(app_params)
    assign_simple_attributes(app_params, %i[maryland_resident self_certify_disability])
    assign_integer_attributes(app_params, %i[user_id managing_guardian_id])
  end

  def assign_transformed_attributes(app_params)
    self.annual_income = app_params[:annual_income]&.gsub(/[^\d.]/, '') if app_params[:annual_income]
    self.household_size = app_params[:household_size]&.to_i if app_params[:household_size]
  end

  def assign_simple_attributes(app_params, fields)
    fields.each do |field|
      send("#{field}=", app_params[field]) if app_params.key?(field)
    end
  end

  def assign_integer_attributes(app_params, fields)
    fields.each do |field|
      value = app_params[field]
      send("#{field}=", value.present? ? value.to_i : nil) if app_params.key?(field)
    end
  end

  def assign_file_attachments(app_params)
    self.residency_proof = app_params[:residency_proof] if app_params[:residency_proof]
    self.income_proof = app_params[:income_proof] if app_params[:income_proof]
    self.id_proof = app_params[:id_proof] if app_params[:id_proof]
  end

  def assign_disability_attributes(app_params)
    ParamCasting::USER_DISABILITY_FIELDS.each do |field|
      send("#{field}=", app_params[field]) if app_params.key?(field)
    end
  end

  def extract_address_attributes(app_params)
    self.physical_address_1 = app_params[:physical_address_1] if app_params[:physical_address_1]
    self.physical_address_2 = app_params[:physical_address_2] if app_params[:physical_address_2]
    self.city = app_params[:city] if app_params[:city]
    self.state = app_params[:state] if app_params[:state]
    self.zip_code = app_params[:zip_code] if app_params[:zip_code]
  end

  def extract_locale_attribute(params, app_params)
    selected_locale = params.dig(:constituent, :locale) || app_params[:locale]
    self.locale = selected_locale if selected_locale.present?
  end

  def extract_medical_provider_attributes(params)
    # Check nested attributes first
    if params.dig(:application, :medical_provider_attributes).present?
      mp_attrs = params[:application][:medical_provider_attributes]
      assign_medical_provider_attributes(mp_attrs)
    # Check top-level params (used in tests)
    elsif params[:medical_provider].present?
      assign_medical_provider_attributes(params[:medical_provider])
    end
  end

  def assign_medical_provider_attributes(mp_attrs)
    self.medical_provider_name = mp_attrs[:name] if mp_attrs[:name]
    self.medical_provider_phone = mp_attrs[:phone] if mp_attrs[:phone]
    self.medical_provider_fax = mp_attrs[:fax] if mp_attrs[:fax]
    self.medical_provider_email = mp_attrs[:email] if mp_attrs[:email]
  end

  def extract_alternate_contact_attributes(app_params)
    self.alternate_contact_name = app_params[:alternate_contact_name] if app_params.key?(:alternate_contact_name)
    self.alternate_contact_phone = app_params[:alternate_contact_phone] if app_params.key?(:alternate_contact_phone)
    self.alternate_contact_email = app_params[:alternate_contact_email] if app_params.key?(:alternate_contact_email)
    self.alternate_contact_relationship_type = app_params[:alternate_contact_relationship_type] if app_params.key?(:alternate_contact_relationship_type)
  end

  def determine_applicant_user
    return current_user unless for_dependent?

    dependent = current_user.dependents.find_by(id: user_id)
    unless dependent
      errors.add(:user_id, 'is not a valid dependent.')
      return nil
    end

    dependent
  end

  # Validations
  def validate_disability_selection
    return unless applicant_user

    disability_fields = [hearing_disability, vision_disability, speech_disability,
                         mobility_disability, cognition_disability]

    return if disability_fields.any?

    errors.add(:base, 'At least one disability must be selected for the applicant before submitting an application.')
  end

  def validate_guardian_relationship
    return unless for_dependent? && applicant_user

    relationship = GuardianRelationship.find_by(
      guardian_id: current_user.id,
      dependent_id: applicant_user.id
    )

    return if relationship

    errors.add(:user_id, 'No valid guardian relationship found.')
  end

  def validate_medical_provider
    return unless is_submission

    return unless medical_provider_name.blank? || medical_provider_phone.blank? || medical_provider_email.blank?

    errors.add(:base, 'Medical provider information is required for submission.')
  end

  def income_collection_required?
    if application&.persisted?
      application.income_proof_required?
    else
      FeatureFlag.enabled?(:income_proof_required)
    end
  end
end
