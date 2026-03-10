# frozen_string_literal: true

class ApplicationNotificationsMailer < ApplicationMailer
  layout false
  include Rails.application.routes.url_helpers
  include Mailers::ApplicationNotificationsHelper
  include Mailers::SharedPartialHelpers # Include the shared helpers

  def self.default_url_options
    Rails.application.config.action_mailer.default_url_options
  end

  def application_submitted(application)
    @application = application
    @user = application.user

    with_mailer_error_handling("application_submitted application=#{application&.id}") do
      template_name = 'application_notifications_application_submitted'
      text_template = find_text_template(template_name)
      variables     = build_application_submitted_variables(application)
      mail_options  = { message_stream: 'notifications' }
      mail_options[:cc] = @application.alternate_contact_email if @application.alternate_contact_email.present?

      if prefers_letter_delivery?(@user)
        queue_letter_delivery(
          recipient: @user,
          template_name: template_name,
          variables: variables,
          application: application
        )
        return noop_letter_delivery
      end

      send_email(recipient_email_for(@user), text_template, variables, mail_options)
    end
  end

  helper Mailers::ApplicationNotificationsHelper

  def proof_approved(application, proof_review)
    with_mailer_error_handling("proof_approved application=#{application&.id} proof_review=#{proof_review&.id}") do
      template_name = 'application_notifications_proof_approved'
      text_template = find_text_template(template_name)
      variables = build_proof_approved_variables(application, proof_review)

      if prefers_letter_delivery?(application.user)
        queue_letter_delivery(
          recipient: application.user,
          template_name: template_name,
          variables: variables.merge(proof_type: proof_review.proof_type),
          letter_type: :proof_approved,
          application: application
        )
        return noop_letter_delivery
      end

      send_email(recipient_email_for(application.user), text_template, variables)
    end
  end

  def proof_rejected(application, proof_review)
    with_mailer_error_handling("proof_rejected application=#{application&.id} proof_review=#{proof_review&.id}") do
      remaining_attempts   = 8 - application.total_rejections
      reapply_date         = 3.years.from_now.to_date
      template_name        = 'application_notifications_proof_rejected'
      text_template        = find_text_template(template_name)
      variables            = build_proof_rejected_variables(
        application,
        proof_review,
        remaining_attempts,
        reapply_date
      )

      if prefers_letter_delivery?(application.user)
        queue_letter_delivery(
          recipient: application.user,
          template_name: template_name,
          variables: variables.merge(proof_type: proof_review.proof_type),
          letter_type: proof_rejection_letter_type(proof_review.proof_type),
          application: application
        )
        return noop_letter_delivery
      end

      send_proof_rejected_email(application.user, text_template, variables)
    end
  end

  def max_rejections_reached(application)
    Rails.logger.info "Preparing max_rejections_reached email for Application ID: #{application.id}"
    Rails.logger.info "Delivery method: #{ActionMailer::Base.delivery_method}"

    with_mailer_error_handling("max_rejections_reached application=#{application&.id}",
                               raise_in_test_only: true) do
      reapply_date  = 3.years.from_now.to_date
      template_name = 'application_notifications_max_rejections_reached'
      text_template = find_text_template(template_name)
      variables     = build_max_rejections_variables(application, reapply_date)

      if prefers_letter_delivery?(application.user)
        queue_letter_delivery(
          recipient: application.user,
          template_name: template_name,
          variables: variables,
          letter_type: :max_rejections_reached,
          application: application
        )
        return noop_letter_delivery
      end

      send_email(recipient_email_for(application.user), text_template, variables)
    end
  end

  def proof_needs_review_reminder(admin, applications)
    with_mailer_error_handling("proof_needs_review_reminder admin=#{admin&.id}",
                               raise_in_test_only: true) do
      stale_reviews = filter_stale_reviews(applications)

      return handle_no_stale_reviews if stale_reviews.empty? && !Rails.env.test?

      text_template = find_text_template('application_notifications_proof_needs_review_reminder')
      variables     = build_review_reminder_variables(admin, stale_reviews)

      send_email(admin.email, text_template, variables)
    end
  end

  def account_created(constituent, temp_password)
    with_mailer_error_handling("account_created constituent=#{constituent&.id}") do
      return handle_nil_constituent if constituent.nil?

      template_name = 'application_notifications_account_created'
      text_template   = find_text_template(template_name)
      variables       = build_account_created_variables(constituent, temp_password)
      recipient_email = extract_recipient_email(constituent)

      if prefers_letter_delivery?(constituent)
        queue_letter_delivery(
          recipient: constituent,
          template_name: template_name,
          variables: variables,
          letter_type: :account_created
        )
        return noop_letter_delivery
      end

      send_email(recipient_email, text_template, variables)
    end
  end

  def income_threshold_exceeded(constituent_params, notification_params, delivery_preference_override: nil)
    with_mailer_error_handling('income_threshold_exceeded') do
      template_name = 'application_notifications_income_threshold_exceeded'
      service_result = get_income_threshold_data(constituent_params, notification_params)
      text_template  = find_text_template(template_name)
      variables      = build_income_threshold_variables(service_result)

      if prefers_letter_delivery?(constituent_params, override: delivery_preference_override)
        queue_letter_delivery(
          recipient: constituent_params,
          template_name: template_name,
          variables: variables,
          letter_type: :income_threshold_exceeded
        )
        return noop_letter_delivery
      end

      send_email(service_result[:constituent][:email], text_template, variables)
    end
  end

  def proof_submission_error(constituent, application, _error_type, message)
    with_mailer_error_handling("proof_submission_error constituent=#{constituent&.id} application=#{application&.id}") do
      recipient_info = determine_proof_error_recipient(constituent, message)
      template_name  = 'application_notifications_proof_submission_error'
      text_template  = find_text_template(template_name)
      variables      = build_proof_error_variables(recipient_info[:full_name], message)

      if constituent.present? && prefers_letter_delivery?(constituent)
        queue_letter_delivery(
          recipient: constituent,
          template_name: template_name,
          variables: variables,
          letter_type: :proof_submission_error,
          application: application
        )
        return noop_letter_delivery
      end

      send_email(recipient_info[:email], text_template, variables)
    end
  end

  def registration_confirmation(user)
    with_mailer_error_handling("registration_confirmation user=#{user&.id}") do
      active_vendors_text_list = build_active_vendors_list
      template_name            = 'application_notifications_registration_confirmation'
      text_template            = find_text_template(template_name)
      variables                = build_registration_variables(user, active_vendors_text_list)

      if prefers_letter_delivery?(user)
        queue_letter_delivery(
          recipient: user,
          template_name: template_name,
          variables: variables,
          letter_type: :registration_confirmation
        )
        return noop_letter_delivery
      end

      send_email(recipient_email_for(user), text_template, variables)
    end
  end

  def proof_received(application, proof_type)
    with_mailer_error_handling("proof_received application=#{application&.id}") do
      template_name = 'application_notifications_proof_received'
      text_template    = find_text_template(template_name)
      variables        = build_proof_received_variables(application, proof_type)
      subject_override = proc { |subject| subject.gsub(/approved/i, 'received').gsub(/Approved/i, 'Received') }

      if prefers_letter_delivery?(application.user)
        queue_letter_delivery(
          recipient: application.user,
          template_name: template_name,
          variables: variables.merge(proof_type: proof_type),
          application: application
        )
        return noop_letter_delivery
      end

      send_email(recipient_email_for(application.user), text_template, variables, { subject_override: subject_override })
    end
  end

  def medical_certification_not_provided(application)
    template_name = 'application_notifications_medical_certification_not_provided'
    text_template = find_text_template(template_name)

    variables = build_medical_certification_not_provided_variables(application)

    if prefers_letter_delivery?(application.user)
      queue_letter_delivery(
        recipient: application.user,
        template_name: template_name,
        variables: variables,
        application: application
      )
      return noop_letter_delivery
    end

    send_email(recipient_email_for(application.user), text_template, variables)
  rescue StandardError => e
    Rails.logger.error("Failed to send medical certification not provided email for application #{application&.id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e
  end

  private

  def with_mailer_error_handling(context, raise_in_test_only: false)
    yield
  rescue StandardError => e
    Rails.logger.error("Mailer error (#{context}): #{e.message}\n#{e.backtrace.join("\n")}")
    raise if !raise_in_test_only || Rails.env.test?

    noop_delivery
  end

  def build_base_email_variables(header_title, organization_name = nil)
    org_name = organization_name || Policy.get('organization_name') || 'Maryland Accessible Telecommunications'
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = root_url(host: default_url_options[:host])
    header_logo_url = safe_asset_path('logo.png')

    {
      header_text: header_text(title: header_title, logo_url: header_logo_url),
      footer_text: footer_text(
        contact_email: footer_contact_email,
        website_url: footer_website_url,
        organization_name: org_name,
        show_automated_message: true
      ),
      header_logo_url: header_logo_url,
      header_subtitle: nil,
      support_email: footer_contact_email
    }
  end

  def safe_asset_path(asset_name)
    ActionController::Base.helpers.asset_path(asset_name, host: default_url_options[:host])
  rescue StandardError
    nil
  end

  def build_proof_approved_variables(application, proof_review)
    user                      = application.user
    organization_name         = Policy.get('organization_name') || 'MAT Program'
    proof_type_formatted      = format_proof_type(proof_review.proof_type)
    all_proofs_approved       = application.respond_to?(:all_proofs_approved?) && application.all_proofs_approved?
    all_proofs_approved_text  = all_proofs_approved ? 'All required documents for your application have now been approved.' : ''
    header_title              = "Document Review Update: #{proof_type_formatted.capitalize} Approved"
    base_variables            = build_base_email_variables(header_title, 'MAT Program')

    base_variables.merge({
                           user_first_name: user.first_name,
                           organization_name: organization_name,
                           proof_type_formatted: proof_type_formatted,
                           all_proofs_approved_message_text: all_proofs_approved_text
                         }).compact
  end

  def build_proof_rejected_variables(application, proof_review, remaining_attempts, reapply_date)
    user                 = application.user
    proof_type_formatted = format_proof_type(proof_review.proof_type)
    header_title         = "Document Review Update: #{proof_type_formatted.capitalize} Needs Revision"
    base_variables       = build_base_email_variables(header_title, 'MAT Program')
    sign_in_url_value    = sign_in_url(host: default_url_options[:host])

    proof_variables = {
      user_first_name: user.first_name,
      constituent_full_name: user.full_name,
      organization_name: 'MAT Program',
      proof_type_formatted: proof_type_formatted,
      rejection_reason: proof_review.rejection_reason,
      additional_instructions: proof_review.notes,
      sign_in_url: sign_in_url_value
    }

    base_variables.merge(proof_variables)
                  .merge(build_proof_rejected_conditional_variables(remaining_attempts, reapply_date, sign_in_url_value))
                  .compact
  end

  def build_proof_rejected_conditional_variables(remaining_attempts, reapply_date, sign_in_url_value)
    if remaining_attempts.positive?
      {
        remaining_attempts_message_text: build_remaining_attempts_message(remaining_attempts, reapply_date),
        default_options_text: "Please sign in to your account at #{sign_in_url_value} to upload the corrected documents or reply to this email with the documents attached.",
        archived_message_text: ''
      }
    else
      {
        remaining_attempts_message_text: '',
        default_options_text: '',
        archived_message_text: build_archived_message(reapply_date)
      }
    end
  end

  def build_remaining_attempts_message(remaining_attempts, reapply_date)
    "You have #{remaining_attempts} #{'attempt'.pluralize(remaining_attempts)} remaining to submit the required documentation before #{reapply_date.strftime('%B %d, %Y')}."
  end

  def build_archived_message(reapply_date)
    "Unfortunately, you have reached the maximum number of submission attempts. Your application has been archived. You may reapply after #{reapply_date.strftime('%B %d, %Y')}."
  end

  def send_proof_rejected_email(user, text_template, variables)
    send_email(
      recipient_email_for(user),
      text_template,
      variables,
      reply_to: ["proof@#{default_url_options[:host]}"]
    )
  end

  def build_max_rejections_variables(application, reapply_date)
    base_variables = build_base_email_variables('Important: Application Status Update', nil)
    base_variables.merge({
                           user_first_name: application.user.first_name,
                           application_id: application.id,
                           reapply_date_formatted: reapply_date.strftime('%B %d, %Y')
                         }).compact
  end

  def filter_stale_reviews(applications)
    applications.select do |app|
      app.respond_to?(:needs_review_since) &&
        app.needs_review_since.present? &&
        app.needs_review_since < 3.days.ago
    end
  end

  def handle_no_stale_reviews
    Rails.logger.info('No stale reviews found, skipping reminder email')
    nil
  end

  def build_review_reminder_variables(admin, stale_reviews)
    admin_dashboard_url = admin_applications_url(host: default_url_options[:host])
    stale_reviews_text_list = build_stale_reviews_list(stale_reviews)
    base_variables = build_base_email_variables('Reminder: Applications Awaiting Proof Review', nil)

    base_variables.merge({
                           admin_first_name: admin.first_name,
                           admin_full_name: admin.full_name,
                           stale_reviews_count: stale_reviews.count,
                           stale_reviews_text_list: stale_reviews_text_list,
                           admin_dashboard_url: admin_dashboard_url
                         }).compact
  end

  def build_stale_reviews_list(stale_reviews)
    stale_reviews.map do |app|
      submitted_date = app.needs_review_since&.strftime('%Y-%m-%d') || 'N/A'
      "- ID: #{app.id}, Name: #{app.user&.full_name || 'N/A'}, Submitted: #{submitted_date}"
    end.join("\n")
  end

  # --- Account created ---

  def handle_nil_constituent
    context = Rails.env.test? ? '[TEST_EDGE_CASE] ' : '[DATA_INTEGRITY] '
    Rails.logger.error("#{context}ApplicationNotificationsMailer#account_created called with nil constituent")
    nil
  end

  def build_account_created_variables(constituent, temp_password)
    header_title   = 'Your MAT Application Account Has Been Created'
    base_variables = build_base_email_variables(header_title, nil)

    is_paper_app = constituent.applications.order(created_at: :desc).first&.submission_method_paper?

    variables = {
      constituent_first_name: constituent.first_name,
      header_title: header_title,
      footer_contact_email: Policy.get('support_email') || 'mat.program1@maryland.gov',
      footer_website_url: root_url(host: default_url_options[:host]),
      footer_show_automated_message: true
    }

    unless is_paper_app
      variables.merge!({
                         constituent_email: constituent.email,
                         temp_password: temp_password,
                         sign_in_url: sign_in_url(host: default_url_options[:host])
                       })
    end

    base_variables.merge(variables).compact
  end

  def extract_recipient_email(constituent)
    return constituent[:email] if constituent.is_a?(Hash)

    recipient_email_for(constituent)
  end

  # --- Income threshold exceeded ---

  def get_income_threshold_data(constituent_params, notification_params)
    result = Notifications::IncomeThresholdService.call(constituent_params, notification_params)

    unless result.success?
      constituent_id = constituent_params.is_a?(Hash) ? constituent_params[:id] : constituent_params&.id
      Rails.logger.error("Failed to prepare income threshold data for constituent #{constituent_id}: #{result.error_message}")
      raise result.error_message
    end

    {
      constituent: result.data[:constituent],
      notification: result.data[:notification],
      threshold_data: result.data[:threshold_data],
      threshold: result.data[:threshold]
    }
  end

  def build_income_threshold_variables(service_result)
    constituent    = service_result[:constituent]
    notification   = service_result[:notification]
    threshold_data = service_result[:threshold_data]
    threshold      = service_result[:threshold]

    status_box_title   = 'Application Status: Income Threshold Exceeded'
    status_box_message = "Based on the information provided, your household income exceeds the program's limit."
    base_variables     = build_base_email_variables('Important Information About Your MAT Application', nil)

    base_variables.merge({
                           constituent_first_name: constituent[:first_name],
                           household_size: threshold_data[:household_size],
                           annual_income_formatted: ActionController::Base.helpers.number_to_currency(notification[:annual_income]),
                           threshold_formatted: ActionController::Base.helpers.number_to_currency(threshold),
                           status_box_text: status_box_text(status: 'error', title: status_box_title, message: status_box_message),
                           additional_notes: notification[:additional_notes]
                         }).compact
  end

  # --- Proof submission error ---

  def determine_proof_error_recipient(constituent, message)
    if constituent
      {
        email: recipient_email_for(constituent),
        full_name: constituent.full_name
      }
    else
      {
        email: message.match(/from: ([^\s]+@[^\s]+)/)&.captures&.first || 'system@mdmat.org',
        full_name: 'System User'
      }
    end
  end

  def build_proof_error_variables(constituent_full_name, message)
    base_variables = build_base_email_variables('Error Processing Your Proof Submission', nil)

    base_variables.merge({
                           constituent_full_name: constituent_full_name,
                           message: message
                         }).compact
  end

  # --- Registration confirmation ---

  def build_active_vendors_list
    active_vendors = Vendor.active.order(:business_name)
    if active_vendors.any?
      active_vendors.map { |v| "- #{v.business_name}" }.join("\n")
    else
      'No authorized vendors found at this time.'
    end
  end

  def build_registration_variables(user, active_vendors_text_list)
    organization_name = Policy.get('organization_name') || 'Maryland Accessible Telecommunications'
    base_variables    = build_base_email_variables(
      'Welcome to the Maryland Accessible Telecommunications Program',
      organization_name
    )

    base_variables.merge({
                           user_first_name: user.first_name,
                           user_full_name: user.full_name,
                           dashboard_url: constituent_portal_dashboard_url(host: default_url_options[:host]),
                           new_application_url: new_constituent_portal_application_url(host: default_url_options[:host]),
                           active_vendors_text_list: active_vendors_text_list
                         }).compact
  end

  # --- Application submitted ---

  def build_application_submitted_variables(application)
    base_variables = build_base_email_variables('Your Application Has Been Submitted', nil)

    variables = {
      user_first_name: application.user.first_name,
      application_id: application.id,
      submission_date_formatted: application.application_date&.strftime('%B %d, %Y') || Time.current.strftime('%B %d, %Y')
    }

    unless application.submission_method_paper?
      variables[:sign_in_url] = "You can track the status of your application at any time by logging into your account: #{sign_in_url(host: default_url_options[:host])}"
    end

    base_variables.merge(variables).compact
  end

  # --- Proof received ---

  def build_proof_received_variables(application, proof_type)
    user                 = application.user
    organization_name    = Policy.get('organization_name') || 'MAT Program'
    proof_type_formatted = format_proof_type(proof_type)
    base_variables       = build_base_email_variables("Document Received: #{proof_type_formatted.capitalize}",
                                                      organization_name)

    base_variables.merge({
                           user_first_name: user.first_name,
                           organization_name: organization_name,
                           proof_type_formatted: proof_type_formatted
                         }).compact
  end

  # Medical certification not provided specific methods
  def build_medical_certification_not_provided_variables(application)
    user = application.user
    header_title = 'Disability Certification Required for Your Application'

    rejection_reason_message = application.medical_certification_rejection_reason.presence || ''

    base_variables = build_base_email_variables(header_title)
    cert_variables = {
      user_first_name: user.first_name,
      rejection_reason_message: rejection_reason_message,
      application_id: application.id
    }

    base_variables.merge(cert_variables).compact
  end

  def proof_rejection_letter_type(proof_type)
    case proof_type.to_s
    when 'income'
      :income_proof_rejected
    when 'residency'
      :residency_proof_rejected
    else
      :other_notification
    end
  end
end
