# frozen_string_literal: true

class EmailTemplate < ApplicationRecord
  before_validation :set_default_version

  # Define enum for format before validations that might use it
  # html: 0, text: 1
  enum :format, { html: 0, text: 1 }

  belongs_to :updated_by, class_name: 'User', optional: true

  scope :enabled, -> { where(enabled: true) }
  scope :disabled_templates, -> { where(enabled: false) }

  # Ensure name is unique within the scope of its format (e.g., 'welcome.html' and 'welcome.text' are distinct)
  validates :name, presence: true, uniqueness: { scope: :format }
  validates :subject, presence: true
  validates :body, presence: true
  validates :format, presence: true
  validates :description, presence: true
  validates :version, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validate :validate_body_uses_only_allowed_variables
  validate :validate_variables_in_body

  # Store previous version before saving changes
  before_update :store_previous_content
  before_update :increment_version

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
    end

    [rendered_subject, rendered_body]
  end

  def render_with_tracking(variables, current_user)
    validate_required_variables!(variables)
    rendered_subject, rendered_body = render(variables)

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
    
    if unauthorized_vars.any?
      errors.add(:body, "contains unauthorized variables: #{unauthorized_vars.join(', ')}. Only use: #{allowed.join(', ')}")
    end
  end

  def store_previous_content
    # Only store if subject or body is changing
    return unless subject_changed? || body_changed?

    self.previous_subject = subject_was
    self.previous_body = body_was
  end

  def increment_version
    # Increment version only if subject or body changed
    self.version += 1 if subject_changed? || body_changed?
  end
end
