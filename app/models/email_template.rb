# frozen_string_literal: true

class EmailTemplate < ApplicationRecord
  before_validation :set_default_version
  before_validation :set_default_syntax

  # Define enum for format before validations that might use it
  # html: 0, text: 1
  enum :format, { html: 0, text: 1 }
  enum :syntax, { legacy_percent: 0, liquid: 1 }

  belongs_to :updated_by, class_name: 'User', optional: true

  scope :enabled, -> { where(enabled: true) }
  scope :disabled_templates, -> { where(enabled: false) }

  validates :name, presence: true, uniqueness: { scope: %i[format locale] }
  validates :subject, presence: true
  validates :body, presence: true
  validates :format, presence: true
  validates :syntax, presence: true, if: :syntax_column_available?
  validates :locale, presence: true
  validates :description, presence: true
  validates :version, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validate :validate_template_syntax, if: :syntax_column_available?
  validate :validate_liquid_does_not_include_legacy_placeholders, if: :syntax_column_available?
  validate :validate_liquid_uses_required_variables_only, if: :syntax_column_available?
  validate :validate_template_uses_only_allowed_variables
  validate :validate_variables_in_template
  validate :validate_liquid_feature_enabled, if: :syntax_column_available?
  validate :counterpart_locales_are_synced, on: :update

  before_update :store_previous_content
  before_update :increment_version
  before_update :clear_locale_sync_flags_when_content_changes,
                if: -> { render_content_changed? && locale_out_of_sync? }
  # Flag other locales when this template's content changes (not when catching up a stale locale).
  after_update :flag_counterpart_locales_for_sync,
               if: lambda {
                 saved_render_content_change? && !locale_was_out_of_sync_before_save?
               }

  def self.render(template_name, **vars)
    template = find_by!(name: template_name)
    template.render(**vars)
  end

  def render(**vars)
    EmailTemplates::Renderer.render(template: self, variables: vars)
  end

  def render_with_tracking(variables, current_user)
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
    EmailTemplates::Renderer.extract_variables(subject: subject, body: body, syntax: render_syntax)
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

  def render_syntax
    syntax_column_available? ? syntax.to_s : EmailTemplates::Renderer::LEGACY_SYNTAX
  end

  def locale_out_of_sync?
    locale_needs_sync?
  end

  def locale_was_out_of_sync_before_save?
    locale_needs_sync_before_last_save
  end

  def previous_version?
    version.to_i > 1 && (previous_subject.present? || previous_body.present?)
  end

  private

  def syntax_column_available?
    has_attribute?(:syntax)
  end

  def set_default_version
    self.version ||= 1
  end

  def set_default_syntax
    return unless syntax_column_available?

    self.syntax ||= EmailTemplates::Renderer::LEGACY_SYNTAX
  end

  def validate_template_syntax
    EmailTemplates::Renderer.validate_template_syntax!(subject: subject, body: body, syntax: render_syntax)
  rescue ArgumentError => e
    errors.add(:base, e.message)
  end

  def validate_liquid_does_not_include_legacy_placeholders
    return unless liquid?
    return if legacy_placeholders_in_template.empty?

    errors.add(:base,
               'This template uses Liquid syntax but still has standard placeholders. ' \
               'Re-insert variables from the dropdown, or switch back to Standard.')
  end

  def validate_liquid_uses_required_variables_only
    return unless liquid?
    return if legacy_placeholders_in_template.any?

    optional_used = extract_variables & optional_variables
    return if optional_used.empty?

    errors.add(:body,
               'Liquid templates can only use Required Variables. ' \
               "Move #{optional_used.join(', ')} to Required Variables before using it, or remove it from the template.")
  rescue ArgumentError
    nil
  end

  def validate_variables_in_template
    return if liquid? && legacy_placeholders_in_template.any?

    current_vars = extract_variables

    required_variables.each do |variable|
      next if current_vars.include?(variable)

      errors.add(:body, "Must include the required variable #{placeholder_for(variable)} in the subject or body")
    end
  rescue ArgumentError => e
    errors.add(:base, e.message)
  end

  def validate_template_uses_only_allowed_variables
    unauthorized_vars = extract_variables - allowed_variables

    return unless unauthorized_vars.any?

    errors.add(:body, unavailable_variables_message(unauthorized_vars))
  rescue ArgumentError => e
    errors.add(:base, e.message)
  end

  def placeholder_for(variable)
    render_syntax == EmailTemplates::Renderer::LIQUID_SYNTAX ? "{{ #{variable} }}" : "%<#{variable}>s"
  end

  def legacy_placeholders_in_template
    [subject, body].flat_map do |text|
      text.to_s.scan(EmailTemplates::Renderer::LEGACY_PLACEHOLDER_PATTERN).flatten
    end.uniq
  end

  def unavailable_variables_message(variable_names)
    names = variable_names.join(', ')
    verb = variable_names.one? ? 'is' : 'are'
    "Use variables from Insert Variable only. #{names} #{verb} not available for this template."
  end

  def validate_liquid_feature_enabled
    return unless liquid?

    unless text?
      errors.add(:syntax, 'Liquid email templates are only available for text templates')
      return
    end

    return if FeatureFlag.enabled?(:email_template_liquid)

    errors.add(:syntax, 'Liquid templates are not enabled yet. Contact your administrator.')
  end

  def store_previous_content
    return unless subject_changed? || body_changed?

    self.previous_subject = subject_was
    self.previous_body = body_was
  end

  def increment_version
    self.version += 1 if render_content_changed?
  end

  def render_content_changed?
    subject_changed? || body_changed? || (syntax_column_available? && syntax_changed?)
  end

  def saved_render_content_change?
    saved_change_to_subject? || saved_change_to_body? || (syntax_column_available? && saved_change_to_syntax?)
  end

  def flag_counterpart_locales_for_sync
    EmailTemplate.where(name: name, format: format).where.not(locale: locale)
                 .update_all(locale_needs_sync: true) # rubocop:disable Rails/SkipsModelValidations
  end

  def clear_locale_sync_flags_when_content_changes
    self.locale_needs_sync = false
  end

  def counterpart_locales_are_synced
    # Block content/admin edits that leave stale body/subject untouched.
    # Operational saves (enabled, sync flags, updated_by) are allowed.
    return unless locale_needs_sync?
    return if body_changed? || subject_changed?
    return unless stale_translation_content_changing?

    errors.add(:base, 'This template is out of sync with another locale variant. ' \
                      'Update the body or subject to resolve it, or use "Mark Synced" to dismiss.')
  end

  def stale_translation_content_changing?
    description_changed? || variables_changed? || (syntax_column_available? && syntax_changed?)
  end
end
