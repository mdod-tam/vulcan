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
      text_template = find_email_template(template_name, locale: @user.locale.presence || 'en')
      variables     = build_application_submitted_variables(application)
      mail_options  = { message_stream: 'notifications' }
      mail_options[:cc] = @application.alternate_contact_email if @application.alternate_contact_email.present?

      send_email(@user.effective_email, text_template, variables, mail_options)
    end
  end

  helper Mailers::ApplicationNotificationsHelper

  def proof_approved(application, proof_review)
    with_mailer_error_handling("proof_approved application=#{application&.id} proof_review=#{proof_review&.id}") do
      locale        = application.user.locale.presence || 'en'
      text_template = find_email_template('application_notifications_proof_approved', locale: locale)
      proof_type_formatted = format_proof_type(proof_review.proof_type)

      variables = Variables::ProofApproved.new(
        application, proof_review,
        base_variables: build_base_email_variables(
          "Document Review Update: #{proof_type_formatted.capitalize} Approved",
          'MAT Program'
        )
      ).to_h

      handle_letter_preference(application.user, 'proof_approved', {
                                 proof_type: proof_review.proof_type,
                                 proof_type_formatted: proof_type_formatted,
                                 all_proofs_approved: application.respond_to?(:all_proofs_approved?) && application.all_proofs_approved?,
                                 first_name: application.user.first_name,
                                 last_name: application.user.last_name,
                                 application_id: application.id
                               })

      send_email(application.user.effective_email, text_template, variables)
    end
  end

  def proof_rejected(application, proof_review)
    with_mailer_error_handling("proof_rejected application=#{application&.id} proof_review=#{proof_review&.id}") do
      remaining_attempts   = 8 - application.total_rejections
      reapply_date         = 3.years.from_now.to_date
      proof_type_formatted = format_proof_type(proof_review.proof_type)
      locale               = application.user.locale.presence || 'en'
      text_template        = find_email_template('application_notifications_proof_rejected', locale: locale)

      variables = Variables::ProofRejected.new(
        application, proof_review,
        remaining_attempts: remaining_attempts,
        reapply_date: reapply_date,
        base_variables: build_base_email_variables(
          "Document Review Update: #{proof_type_formatted.capitalize} Needs Revision",
          'MAT Program'
        ),
        sign_in_url: sign_in_url(host: default_url_options[:host])
      ).to_h

      handle_letter_preference(application.user, 'proof_rejected', {
                                 proof_type: proof_review.proof_type,
                                 proof_type_formatted: proof_type_formatted,
                                 rejection_reason: proof_review.rejection_reason || 'Documentation did not meet requirements',
                                 notes: proof_review.notes || '',
                                 remaining_attempts: remaining_attempts,
                                 reapply_date: reapply_date.strftime('%B %d, %Y'),
                                 first_name: application.user.first_name,
                                 last_name: application.user.last_name,
                                 application_id: application.id
                               })

      send_proof_rejected_email(application.user, text_template, variables)
    end
  end

  def max_rejections_reached(application)
    Rails.logger.info "Preparing max_rejections_reached email for Application ID: #{application.id}"
    Rails.logger.info "Delivery method: #{ActionMailer::Base.delivery_method}"

    with_mailer_error_handling("max_rejections_reached application=#{application&.id}") do
      reapply_date  = 3.years.from_now.to_date
      text_template = find_email_template('application_notifications_max_rejections_reached',
                                          locale: application.user.locale.presence || 'en')
      variables     = build_max_rejections_variables(application, reapply_date)

      handle_letter_preference(application.user, 'max_rejections_reached', {
                                 reapply_date_formatted: reapply_date.strftime('%B %d, %Y'),
                                 first_name: application.user.first_name,
                                 last_name: application.user.last_name,
                                 application_id: application.id
                               })

      send_email(application.user.effective_email, text_template, variables)
    end
  end

  def proof_needs_review_reminder(admin, applications)
    with_mailer_error_handling("proof_needs_review_reminder admin=#{admin&.id}") do
      stale_reviews = filter_stale_reviews(applications)

      return handle_no_stale_reviews if stale_reviews.empty? && !Rails.env.test?

      text_template = find_email_template('application_notifications_proof_needs_review_reminder')
      variables     = build_review_reminder_variables(admin, stale_reviews)

      send_email(admin.email, text_template, variables)
    end
  end

  def account_created(constituent, temp_password)
    with_mailer_error_handling("account_created constituent=#{constituent&.id}") do
      return handle_nil_constituent if constituent.nil?

      locale          = constituent.respond_to?(:locale) ? constituent.locale.presence || 'en' : 'en'
      text_template   = find_email_template('application_notifications_account_created', locale: locale)
      variables       = build_account_created_variables(constituent, temp_password)
      recipient_email = extract_recipient_email(constituent)

      handle_letter_preference(constituent, 'account_created', {
                                 email: constituent.email,
                                 temp_password: temp_password,
                                 first_name: constituent.first_name,
                                 last_name: constituent.last_name
                               })

      send_email(recipient_email, text_template, variables)
    end
  end

  def income_threshold_exceeded(constituent_params, notification_params)
    with_mailer_error_handling('income_threshold_exceeded') do
      service_result = get_income_threshold_data(constituent_params, notification_params)
      locale         = service_result[:constituent][:locale].presence || 'en'
      text_template  = find_email_template('application_notifications_income_threshold_exceeded', locale: locale)
      variables      = build_income_threshold_variables(service_result)

      send_email(service_result[:constituent][:email], text_template, variables)
    end
  end

  def proof_submission_error(constituent, application, _error_type, message)
    with_mailer_error_handling("proof_submission_error constituent=#{constituent&.id} application=#{application&.id}") do
      recipient_info = determine_proof_error_recipient(constituent, message)
      locale         = constituent.respond_to?(:locale) ? constituent.locale.presence || 'en' : 'en'
      text_template  = find_email_template('application_notifications_proof_submission_error', locale: locale)
      variables      = build_proof_error_variables(recipient_info[:full_name], message)

      handle_letter_preference(constituent, 'proof_submission_error', {
                                 error_message: message,
                                 first_name: constituent&.first_name,
                                 last_name: constituent&.last_name,
                                 application_id: application&.id
                               })

      send_email(recipient_info[:email], text_template, variables)
    end
  end

  def registration_confirmation(user)
    with_mailer_error_handling("registration_confirmation user=#{user&.id}") do
      active_vendors_text_list = build_active_vendors_list
      text_template            = find_email_template('application_notifications_registration_confirmation',
                                                     locale: user.locale.presence || 'en')
      variables                = build_registration_variables(user, active_vendors_text_list)

      handle_letter_preference(user, 'registration_confirmation', {
                                 user_full_name: user.full_name,
                                 dashboard_url: constituent_portal_dashboard_url(host: default_url_options[:host]),
                                 new_application_url: new_constituent_portal_application_url(host: default_url_options[:host]),
                                 active_vendors_text_list: active_vendors_text_list
                               })

      send_email(user.effective_email, text_template, variables)
    end
  end

  def proof_received(application, proof_type)
    with_mailer_error_handling("proof_received application=#{application&.id}") do
      text_template    = find_email_template('application_notifications_proof_received',
                                             locale: application.user.locale.presence || 'en')
      variables        = build_proof_received_variables(application, proof_type)
      subject_override = proc { |subject| subject.gsub(/approved/i, 'received').gsub(/Approved/i, 'Received') }

      send_email(application.user.effective_email, text_template, variables, { subject_override: subject_override })
    end
  end

  private

  def with_mailer_error_handling(context)
    yield
  rescue StandardError => e
    Rails.logger.error("Mailer error (#{context}): #{e.message}\n#{e.backtrace.join("\n")}")
    raise
  end

  def handle_letter_preference(user, template_key, variables)
    generate_letter_if_preferred(user, "application_notifications_#{template_key}", variables)
  end

  def generate_letter_if_preferred(recipient, template_name, variables)
    return unless recipient.respond_to?(:communication_preference) && recipient.communication_preference == 'letter'

    Letters::TextTemplateToPdfService.new(
      template_name: template_name,
      recipient: recipient,
      variables: variables
    ).queue_for_printing
  end

  def find_email_template(template_name, locale: 'en')
    EmailTemplate.find_by!(name: template_name, format: :text, locale: locale)
  rescue ActiveRecord::RecordNotFound
    raise if locale == 'en'

    Rails.logger.debug { "No #{locale} template for #{template_name}, falling back to English" }
    find_email_template(template_name, locale: 'en')
  end

  def build_base_email_variables(header_title, organization_name = nil)
    org_name = organization_name || Policy.get('organization_name') || 'Maryland Accessible Telecommunications'
    footer_contact_email = Policy.get('support_email') || 'support@example.com'
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
      header_subtitle: nil
    }
  end

  def safe_asset_path(asset_name)
    ActionController::Base.helpers.asset_path(asset_name, host: default_url_options[:host])
  rescue StandardError
    nil
  end

  def send_proof_rejected_email(user, text_template, variables)
    send_email(
      user.email,
      text_template,
      variables,
      reply_to: ["proof@#{default_url_options[:host]}"]
    )
  end

  def build_max_rejections_variables(application, reapply_date)
    base_variables = build_base_email_variables('Important: Application Status Update')
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
    base_variables = build_base_email_variables('Reminder: Applications Awaiting Proof Review')

    base_variables.merge({
                           admin_first_name: admin.first_name,
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
    base_variables = build_base_email_variables(header_title)

    base_variables.merge({
                           constituent_first_name: constituent.first_name,
                           constituent_email: constituent.email,
                           temp_password: temp_password,
                           sign_in_url: sign_in_url(host: default_url_options[:host]),
                           header_title: header_title,
                           footer_contact_email: Policy.get('support_email') || 'support@example.com',
                           footer_website_url: root_url(host: default_url_options[:host]),
                           footer_show_automated_message: true
                         }).compact
  end

  def extract_recipient_email(constituent)
    constituent.is_a?(Hash) ? constituent[:email] : constituent.email
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
    base_variables     = build_base_email_variables('Important Information About Your MAT Application')

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
        email: constituent.email,
        full_name: constituent.full_name
      }
    else
      {
        email: message.match(/from: ([^\s]+@[^\s]+)/)&.captures&.first || 'unknown@example.com',
        full_name: 'Email Sender'
      }
    end
  end

  def build_proof_error_variables(constituent_full_name, message)
    base_variables = build_base_email_variables('Error Processing Your Proof Submission')

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
    base_variables = build_base_email_variables('Your Application Has Been Submitted')

    base_variables.merge({
                           user_first_name: application.user.first_name,
                           application_id: application.id,
                           submission_date_formatted: application.application_date&.strftime('%B %d, %Y') || Time.current.strftime('%B %d, %Y')
                         }).compact
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
end
