# frozen_string_literal: true

class EmailTemplate < ApplicationRecord
  before_validation :set_default_version

  # Define enum for format before validations that might use it
  # html: 0, text: 1
  enum :format, { html: 0, text: 1 }

  belongs_to :updated_by, class_name: 'User', optional: true
  has_many :email_template_snapshots, dependent: :destroy

  scope :enabled, -> { where(enabled: true) }
  scope :disabled_templates, -> { where(enabled: false) }

  validates :name, presence: true, uniqueness: { scope: %i[format locale] }
  validates :subject, presence: true
  validates :body, presence: true
  validates :format, presence: true
  validates :locale, presence: true
  validates :description, presence: true
  validates :version, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validate :validate_body_uses_only_allowed_variables
  validate :validate_variables_in_body
  validate :counterpart_locales_are_synced, on: :update

  before_update :increment_version
  before_update :clear_locale_sync_flags_when_content_changes,
                if: -> { (body_changed? || subject_changed?) && locale_out_of_sync? }
  # Flag other locales when this template's content changes (not when catching up a stale locale).
  after_update :flag_counterpart_locales_for_sync,
               if: lambda {
                 (saved_change_to_body? || saved_change_to_subject?) && !locale_was_out_of_sync_before_save?
               }

  def self.render(template_name, **vars)
    template = find_by!(name: template_name)
    template.render(**vars)
  end

  def render(**vars)
    validate_required_variables!(vars)

    # Simple string substitution approach that works reliably with both formats
    rendered_body = body.dup
    rendered_subject = subject.dup

    vars.each do |key, value|
      # Handle both "%{key}" and "%<key>s" format strings
      rendered_body = rendered_body.gsub("%{#{key}}", value.to_s)
      rendered_body = rendered_body.gsub("%<#{key}>s", value.to_s)

      rendered_subject = rendered_subject.gsub("%{#{key}}", value.to_s)
      rendered_subject = rendered_subject.gsub("%<#{key}>s", value.to_s)

      rendered_body = rendered_body.gsub("%<#{key}>", value.to_s)
      rendered_subject = rendered_subject.gsub("%<#{key}>", value.to_s)
    end

    rendered_body = rendered_body.gsub(/%[<{]\w+[>}]s?/, '')
    rendered_subject = rendered_subject.gsub(/%[<{]\w+[>}]s?/, '')

    [rendered_subject, rendered_body]
  end

  def render_with_tracking(variables, current_user)
    validate_required_variables!(variables)
    rendered_subject, rendered_body = render(**variables)

    AuditEventService.log(
      actor: current_user,
      action: 'email_template_rendered',
      auditable: self,
      metadata: {
        user_agent: Current.user_agent,
        ip_address: Current.ip_address
      }
    )

    [rendered_subject, rendered_body]
  rescue StandardError
    AuditEventService.log(
      actor: current_user,
      action: 'email_template_error',
      auditable: self,
      metadata: {
        user_agent: Current.user_agent,
        ip_address: Current.ip_address
      }
    )
    raise
  end

  # Extract all variables used in the template body
  def extract_variables
    body.scan(/%[{<](\w+)[}>]/).flatten.uniq
  end

  def required_variables
    variables['required'] || []
  end

  def optional_variables
    variables['optional'] || []
  end

  def allowed_variables
    required_variables + optional_variables
  end

  def locale_out_of_sync?
    locale_needs_sync? || needs_sync?
  end

  def locale_was_out_of_sync_before_save?
    locale_needs_sync_before_last_save || needs_sync_before_last_save
  end

  # Snapshots record post-edit state; the prior snapshot is the previous saved version.
  def prior_snapshot
    email_template_snapshots.ordered.offset(1).first
  end

  def legacy_previous_version?
    version.to_i > 1 && (previous_subject.present? || previous_body.present?)
  end

  def snapshot_content_attributes
    {
      subject: subject,
      body: body,
      description: description,
      enabled: enabled,
      variables: variables || {}
    }
  end

  private

  def set_default_version
    self.version ||= 1
  end

  def validate_variables_in_body
    required_variables.each do |variable|
      unless body.to_s.include?("%{#{variable}}") || body.to_s.include?("%<#{variable}>")
        errors.add(:body, "Must include the required variable %{#{variable}} or %<#{variable}>s")
      end
    end
  end

  def validate_required_variables!(vars)
    provided_keys = vars.keys.map(&:to_s)
    missing_vars = required_variables - provided_keys

    return unless missing_vars.any?

    raise ArgumentError, "Missing required variables for template '#{name}': #{missing_vars.join(', ')}"
  end

  def validate_body_uses_only_allowed_variables
    # Get all variables currently written in the body string (e.g. ['name', 'bad_var'])
    current_vars_in_body = extract_variables

    # Get the allowed list from the database (e.g. ['name', 'footer_text'])
    allowed = allowed_variables

    # Find the difference
    unauthorized_vars = current_vars_in_body - allowed

    return unless unauthorized_vars.any?

    errors.add(:body, "contains unauthorized variables: #{unauthorized_vars.join(', ')}. Only use: #{allowed.join(', ')}")
  end

  def increment_version
    # Increment version only if subject or body changed
    self.version += 1 if subject_changed? || body_changed?
  end

  def flag_counterpart_locales_for_sync
    EmailTemplate.where(name: name, format: format).where.not(locale: locale)
                 .update_all(locale_needs_sync: true, needs_sync: true) # rubocop:disable Rails/SkipsModelValidations
  end

  def clear_locale_sync_flags_when_content_changes
    self.locale_needs_sync = false
    self.needs_sync = false
  end

  def counterpart_locales_are_synced
    # Block content/admin edits that leave stale body/subject untouched.
    # Operational saves (enabled, sync flags, updated_by) are allowed.
    return unless locale_out_of_sync?
    return if body_changed? || subject_changed?
    return unless stale_translation_content_changing?

    errors.add(:base, 'This template is out of sync with another locale variant. ' \
                      'Update the body or subject to resolve it, or use "Mark Synced" to dismiss.')
  end

  def stale_translation_content_changing?
    description_changed? || variables_changed?
  end
end
