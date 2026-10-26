# frozen_string_literal: true

# Validates constituent application input. Applications::ApplicationCreator owns persistence.
class ApplicationForm
  include ActiveModel::Model
  include ActiveModel::Attributes
  include ActiveModel::Validations

  # Request inputs written straight to the typed attributes above. Strong parameters drop arrays and
  # hashes, so a malformed value never reaches a boolean or integer writer as a truthy object.
  SCALAR_APPLICATION_PARAMS = %i[
    annual_income household_size maryland_resident self_certify_disability
    hearing_disability vision_disability speech_disability mobility_disability cognition_disability
    terms_accepted information_verified medical_release_authorized use_guardian_address
    user_id managing_guardian_id residency_proof income_proof id_proof
    physical_address_1 physical_address_2 city state zip_code
    alternate_contact_name alternate_contact_phone alternate_contact_email alternate_contact_relationship_type
  ].freeze

  attribute :annual_income, :string
  attribute :status, :string, default: 'draft'
  attribute :submission_method, :string, default: 'online'
  attribute :household_size, :integer
  attribute :maryland_resident, :boolean, default: true
  attribute :self_certify_disability, :boolean, default: true

  attribute :residency_proof
  attribute :income_proof
  attribute :id_proof

  # User attributes
  attribute :hearing_disability, :boolean, default: false
  attribute :vision_disability, :boolean, default: false
  attribute :speech_disability, :boolean, default: false
  attribute :mobility_disability, :boolean, default: false
  attribute :cognition_disability, :boolean, default: false
  attribute :locale, :string

  attribute :physical_address_1, :string
  attribute :physical_address_2, :string
  attribute :city, :string
  attribute :state, :string
  attribute :zip_code, :string
  attribute :use_guardian_address, :boolean, default: false

  attribute :terms_accepted, :boolean, default: false
  attribute :information_verified, :boolean, default: false
  attribute :medical_release_authorized, :boolean, default: false

  attribute :medical_provider_name, :string
  attribute :medical_provider_phone, :string
  attribute :medical_provider_fax, :string
  attribute :medical_provider_email, :string

  attribute :user_id, :integer # Dependent applicant for a new application
  attribute :managing_guardian_id, :integer

  attribute :alternate_contact_name, :string
  attribute :alternate_contact_phone, :string
  attribute :alternate_contact_email, :string
  attribute :alternate_contact_relationship_type, :string

  attribute :is_submission, :boolean, default: false
  attribute :autosave_context, :string
  attribute :autosave_revision, :string

  attr_accessor :current_user, :application

  validates :current_user, presence: true
  validates :annual_income, presence: true, if: -> { is_submission && income_collection_required? }
  validate :validate_disability_selection, if: :is_submission
  validate :validate_guardian_relationship, if: :for_dependent?
  validate :validate_medical_provider, if: :is_submission

  def initialize(attributes = {})
    @current_user = attributes.delete(:current_user)
    @application = attributes.delete(:application)

    if attributes[:params].present?
      params = attributes.delete(:params)
      super
      populate_from_params(params)
    else
      super
    end
  end

  # A persisted application keeps the owner that the actor was authorized to open.
  # The edit form does not post user_id. If this used user_id, every update would resolve to the actor.
  # The submitted user_id decides only for a new application, which has no owner yet.
  def for_dependent?
    return application.user_id.present? && application.user_id != current_user&.id if application&.persisted?

    user_id.present? && user_id != current_user&.id
  end

  def applicant_user
    @applicant_user ||= determine_applicant_user
  end

  def target_application
    @target_application ||= application || Application.new
  end

  # Locale for form-owned messages, in this order: the submitted locale, the applicant locale, the actor locale.
  # The applicant locale follows the guardian for guardian-contact dependents.
  # Callers pass the result to +I18n.t+ and +I18n.with_locale+, so it must be an available locale.
  # An unsupported locale would raise I18n::InvalidLocale instead of showing a message.
  def message_locale
    supported_locale(locale) ||
      applicant_user&.effective_message_locale ||
      current_user&.effective_message_locale ||
      I18n.default_locale
  end

  private

  # Only the submitted locale needs this. User#effective_message_locale allowlists the user locales.
  def supported_locale(value)
    candidate = value.to_s
    return if candidate.blank?

    candidate.to_sym if I18n.available_locales.include?(candidate.to_sym)
  end

  def populate_from_params(params)
    self.autosave_context = params[:autosave_context]
    self.autosave_revision = params[:autosave_revision]
    return if params[:application].blank?

    app_params = params[:application]
    scalars = scalar_params(app_params, *SCALAR_APPLICATION_PARAMS)

    assign_attributes(scalars)
    self.annual_income = annual_income&.gsub(/[^\d.]/, '') if scalars.key?(:annual_income)

    # A top-level checkbox takes precedence over the nested one.
    assign_attributes(scalar_params(params, :use_guardian_address))
    extract_locale_attribute(params, app_params)
    extract_medical_provider_attributes(params)

    self.is_submission = params[:submit_application].present?
  end

  def scalar_params(source, *keys)
    source.slice(*keys).permit(*keys)
  end

  def extract_locale_attribute(params, app_params)
    selected_locale = params.dig(:constituent, :locale) || app_params[:locale]
    self.locale = selected_locale if selected_locale.present?
  end

  def extract_medical_provider_attributes(params)
    if params.dig(:application, :medical_provider_attributes).present?
      mp_attrs = params[:application][:medical_provider_attributes]
      assign_medical_provider_attributes(mp_attrs)
    # Only tests post top-level medical_provider params.
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

  def determine_applicant_user
    # A persisted application uses its authorized owner, never a submitted id.
    # ensure_editable has already authorized the actor for this application.
    return application.user if application&.persisted?

    return current_user unless for_dependent?

    dependent = current_user.dependents.find_by(id: user_id)
    unless dependent
      errors.add(:user_id, 'is not a valid dependent.')
      return nil
    end

    dependent
  end

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

    I18n.with_locale(message_locale) do
      errors.add(:base, :medical_provider_required)
    end
  end

  def income_collection_required?
    if application&.persisted?
      application.income_proof_required?
    else
      FeatureFlag.income_proof_required?
    end
  end
end
