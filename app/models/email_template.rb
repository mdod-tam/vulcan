# frozen_string_literal: true

class EmailTemplate < ApplicationRecord
  before_validation :set_default_version

  # Define enum for format before validations that might use it
  # html: 0, text: 1
  enum :format, { html: 0, text: 1 }

  belongs_to :updated_by, class_name: 'User', optional: true

  # Ensure name is unique within the scope of its format (e.g., 'welcome.html' and 'welcome.text' are distinct)
  validates :name, presence: true, uniqueness: { scope: :format }
  validates :subject, presence: true
  validates :body, presence: true
  validates :format, presence: true
  validates :description, presence: true
  validates :version, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validate :validate_variables_in_body

  # Store previous version before saving changes
  before_update :store_previous_content
  before_update :increment_version

  # The keys should match the base 'name' of the template (e.g., 'user_mailer_password_reset')
  # This list is populated based on the analysis in doc/mailer_template_management.md
  AVAILABLE_TEMPLATES = {
    # ApplicationNotificationsMailer Templates
    'application_notifications_account_created' => {
      description: 'Sent when a new user account is created (e.g., by an admin).',
      # Text-only variables
      required_vars: %w[constituent_first_name constituent_email temp_password sign_in_url header_text footer_text],
      # Optional vars for header/footer text helpers
      optional_vars: %w[title show_automated_message logo subtitle] # title/show_automated_message moved from required as they are optional for helpers
      # NOTE: header_title, footer_contact_email, footer_website_url, header_logo_url, header_subtitle
      # seem to be from an older implementation using Mailers::SharedPartialHelpers directly,
      # which might be superseded by rendering the partials. Keeping them out for now based on template analysis.
    },
    'application_notifications_income_threshold_exceeded' => {
      description: 'Sent when an application is rejected because income exceeds the threshold.',
      required_vars: %w[constituent_first_name household_size annual_income_formatted threshold_formatted header_text footer_text],
      optional_vars: %w[additional_notes status_box_text title logo subtitle show_automated_message] # status_box_text might be optional if not always shown
    },
    'application_notifications_max_rejections_reached' => {
      description: 'Sent when an application reaches the maximum number of proof rejections.',
      required_vars: %w[user_first_name application_id reapply_date_formatted header_text footer_text],
      optional_vars: %w[title logo subtitle show_automated_message]
    },
    'application_notifications_proof_approved' => {
      description: 'Sent when a submitted proof document is approved.',
      required_vars: %w[user_first_name organization_name proof_type_formatted header_text footer_text],
      optional_vars: %w[all_proofs_approved_message_text title logo subtitle show_automated_message]
    },
    'application_notifications_proof_needs_review_reminder' => {
      description: 'Sent to admins as a reminder about applications awaiting proof review.',
      required_vars: %w[admin_full_name stale_reviews_count stale_reviews_text_list admin_dashboard_url header_text footer_text],
      optional_vars: %w[title logo subtitle show_automated_message]
    },
    'application_notifications_proof_rejected' => {
      description: 'Sent when a submitted proof document is rejected.',
      required_vars: %w[constituent_full_name organization_name proof_type_formatted rejection_reason header_text footer_text],
      optional_vars: %w[remaining_attempts_message_text title logo subtitle show_automated_message] # Removed HTML/unused vars
    },
    'application_notifications_proof_submission_error' => {
      description: 'Sent to a constituent when their emailed proof submission fails processing.',
      required_vars: %w[constituent_full_name message header_text footer_text], # Renamed error_message to message based on template
      optional_vars: %w[title logo subtitle show_automated_message]
    },
    'application_notifications_registration_confirmation' => {
      description: 'Sent to a user upon successful account registration confirmation.',
      required_vars: %w[user_full_name dashboard_url new_application_url header_text footer_text active_vendors_text_list],
      optional_vars: %w[title logo subtitle show_automated_message]
    },

    # MedicalProviderMailer Templates
    'medical_provider_certification_rejected' => {
      description: 'Sent to a medical provider when a submitted certification is rejected.', # Added description
      required_vars: %w[constituent_full_name application_id rejection_reason remaining_attempts],
      optional_vars: []
    },
    'medical_provider_request_certification' => {
      description: 'Sent to a medical provider requesting certification for an application.', # Added description
      required_vars: %w[constituent_full_name request_count_message timestamp_formatted constituent_dob_formatted
                        constituent_address_formatted application_id download_form_url],
      optional_vars: []
    },
    'medical_provider_certification_submission_error' => {
      description: 'Sent to a medical provider when their emailed certification submission fails processing (e.g., cannot find application, attachment error).',
      required_vars: %w[medical_provider_email error_message],
      optional_vars: %w[constituent_full_name application_id]
    },

    # EvaluatorMailer Templates
    'evaluator_mailer_evaluation_submission_confirmation' => {
      description: 'Sent to a constituent confirming their evaluation was submitted.',
      required_vars: %w[constituent_first_name application_id evaluator_full_name submission_date_formatted header_text footer_text status_box_text],
      optional_vars: %w[title logo subtitle show_automated_message]
    },
    'evaluator_mailer_new_evaluation_assigned' => {
      description: 'Sent to an evaluator when a new evaluation is assigned to them.',
      required_vars: %w[evaluator_full_name constituent_full_name constituent_address_formatted constituent_phone_formatted
                        constituent_email evaluators_evaluation_url header_text footer_text status_box_text constituent_disabilities_text_list],
      optional_vars: %w[title logo subtitle show_automated_message]
    },

    # UserMailer Templates
    'user_mailer_email_verification' => {
      description: 'Sent to a user to verify their email address.', # Added description
      required_vars: %w[user_email verification_url],
      optional_vars: []
    },
    'user_mailer_password_reset' => {
      description: 'Sent to a user to allow them to reset their password.', # Added description
      required_vars: %w[user_email reset_url],
      optional_vars: []
    },

    # VendorNotificationsMailer Templates
    'vendor_notifications_invoice_generated' => {
      description: 'Sent to a vendor when a new invoice is generated for their transactions.',
      required_vars: %w[vendor_business_name invoice_number period_start_formatted period_end_formatted total_amount_formatted
                        transactions_text_list], # Removed _html_table
      optional_vars: [] # No header/footer used in this template
    },
    'vendor_notifications_payment_issued' => {
      description: 'Sent to a vendor when payment has been issued for an invoice.',
      required_vars: %w[vendor_business_name invoice_number total_amount_formatted gad_invoice_reference],
      optional_vars: %w[check_number]
    },
    'vendor_notifications_w9_approved' => {
      description: 'Sent to a vendor when their submitted W9 form is approved.',
      required_vars: %w[vendor_business_name status_box_text header_text footer_text],
      optional_vars: %w[title logo subtitle show_automated_message] # title was required before, now optional helper arg
    },
    'vendor_notifications_w9_rejected' => {
      description: 'Sent to a vendor when their submitted W9 form is rejected.',
      required_vars: %w[vendor_business_name rejection_reason vendor_portal_url status_box_text header_text footer_text],
      optional_vars: %w[title logo subtitle show_automated_message] # title was required before, now optional helper arg
    },
    'vendor_notifications_w9_expiring_soon' => {
      description: 'Sent to a vendor as a reminder that their W9 form is expiring soon.',
      required_vars: %w[vendor_business_name days_until_expiry expiration_date_formatted vendor_portal_url
                        status_box_warning_text status_box_info_text header_text footer_text],
      optional_vars: %w[vendor_association_message title logo subtitle show_automated_message] # title was required before, now optional helper arg
    },
    'vendor_notifications_w9_expired' => {
      description: 'Sent to a vendor when their W9 form has expired.',
      required_vars: %w[vendor_business_name expiration_date_formatted vendor_portal_url
                        status_box_warning_text status_box_info_text header_text footer_text],
      optional_vars: %w[vendor_association_message title logo subtitle show_automated_message] # title was required before, now optional helper arg
    },

    # VoucherNotificationsMailer Templates
    'voucher_notifications_voucher_assigned' => {
      description: 'Sent to a constituent when a voucher is assigned to them.', # Added description
      required_vars: %w[user_first_name voucher_code initial_value_formatted expiration_date_formatted validity_period_months
                        minimum_redemption_amount_formatted],
      optional_vars: []
    },
    'voucher_notifications_voucher_expired' => {
      description: 'Sent to a constituent when their voucher has expired.',
      required_vars: %w[user_first_name voucher_code initial_value_formatted unused_value_formatted expiration_date_formatted
                        header_text footer_text], # Added header/footer, removed unused vars
      optional_vars: %w[transaction_history_text title logo subtitle show_automated_message] # Removed HTML var
    },
    'voucher_notifications_voucher_redeemed' => {
      description: 'Sent to a constituent when their voucher is redeemed.',
      required_vars: %w[user_first_name transaction_date_formatted transaction_amount_formatted vendor_business_name
                        transaction_reference_number voucher_code remaining_balance_formatted expiration_date_formatted
                        remaining_value_message_text fully_redeemed_message_text], # Removed HTML vars
      optional_vars: %w[minimum_redemption_amount_formatted] # No header/footer used in this template
    },

    # TrainingSessionNotificationsMailer Templates
    'training_session_notifications_trainer_assigned' => {
      description: 'Sent to a trainer when a new training session is assigned to them.',
      required_vars: %w[trainer_full_name constituent_full_name constituent_address_formatted constituent_phone_formatted
                        constituent_email training_session_schedule_text header_text footer_text constituent_disabilities_text_list status_box_text],
      optional_vars: %w[title logo subtitle show_automated_message]
    },
    'training_session_notifications_training_scheduled' => {
      description: 'Sent to a constituent when their training session is scheduled.',
      required_vars: %w[constituent_full_name trainer_full_name scheduled_date_formatted scheduled_time_formatted trainer_email
                        trainer_phone_formatted header_text footer_text],
      optional_vars: %w[title logo subtitle show_automated_message]
    },
    'training_session_notifications_training_completed' => {
      description: 'Sent to a constituent when their training session is marked as completed.',
      required_vars: %w[constituent_full_name trainer_full_name completed_date_formatted application_id trainer_email
                        trainer_phone_formatted header_text footer_text],
      optional_vars: %w[title logo subtitle show_automated_message]
    },
    'training_session_notifications_training_cancelled' => {
      description: 'Sent to a constituent when their scheduled training session is cancelled.',
      required_vars: %w[constituent_full_name scheduled_date_time_formatted support_email header_text footer_text],
      optional_vars: %w[title logo subtitle show_automated_message]
    },
    'training_session_notifications_training_no_show' => { # NOTE: Mailer uses 'training_no_show' in find_by, but we use full name here
      description: 'Sent to a constituent if they are marked as a no-show for their training session.',
      required_vars: %w[constituent_full_name scheduled_date_time_formatted support_email header_text footer_text],
      optional_vars: %w[title logo subtitle show_automated_message]
    }
  }.freeze

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

    Event.create!(
      user: current_user,
      action: 'email_template_rendered',
      user_agent: Current.user_agent,
      ip_address: Current.ip_address
    )

    [rendered_subject, rendered_body]
  rescue StandardError
    Event.create!(
      user: current_user,
      action: 'email_template_error',
      user_agent: Current.user_agent,
      ip_address: Current.ip_address
    )
    raise
  end

  # Extract all variables used in the template body
  def extract_variables
    body.scan(/%[{<](\w+)[}>]/).flatten.uniq
  end

  private

  def set_default_version
    self.version ||= 1
  end

  def validate_variables_in_body
    # Ensure name is a string for hash lookup
    template_config = AVAILABLE_TEMPLATES[name.to_s]
    return unless template_config # Skip validation if template name is not in the constant

    required_vars = template_config[:required_vars] || []

    required_vars.each do |var|
      # Check for either %{variable} or %<variable>s format
      errors.add(:body, "must include the variable %{#{var}} or %<#{var}>s") unless body.to_s.include?("%{#{var}}") || body.to_s.include?("%<#{var}>")
    end
  end

  def validate_required_variables!(vars)
    # Ensure name is a string for hash lookup
    template_config = AVAILABLE_TEMPLATES[name.to_s]
    return unless template_config # Skip validation if template name is not in the constant

    required_vars = template_config[:required_vars] || []
    missing_vars = required_vars - vars.keys.map(&:to_s)

    return unless missing_vars.any?

    raise ArgumentError, "Missing required variables for template '#{name}': #{missing_vars.join(', ')}"
  end

  # Helper method to get required variables based on name
  def required_variables
    AVAILABLE_TEMPLATES[name.to_s]&.dig(:required_vars) || []
  end

  # Helper method to get optional variables based on name
  def optional_variables
    AVAILABLE_TEMPLATES[name.to_s]&.dig(:optional_vars) || []
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
