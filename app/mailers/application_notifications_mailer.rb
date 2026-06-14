# frozen_string_literal: true

class ApplicationNotificationsMailer < ApplicationMailer # rubocop:disable Metrics/ClassLength
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
      locale        = resolve_template_locale(recipient: @user)
      text_template = find_text_template(template_name, locale: locale)
      variables     = build_application_submitted_variables(application, template: text_template, locale: locale)
      mail_options = { message_stream: 'notifications' }

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

  def training_requested(application, notification)
    with_mailer_error_handling("training_requested application=#{application&.id} notification=#{notification&.id}") do
      admin = notification.recipient
      template_name = 'application_notifications_training_requested'
      locale        = staff_template_locale
      text_template = find_text_template(template_name, locale: locale)
      variables     = build_training_requested_variables(
        application,
        notification,
        template: text_template,
        locale: locale
      )
      mail_options = { message_stream: 'notifications' }

      if prefers_letter_delivery?(admin)
        queue_letter_delivery(
          recipient: admin,
          template_name: template_name,
          variables: variables,
          application: application
        )
        return noop_letter_delivery
      end

      send_email(recipient_email_for(admin), text_template, variables, mail_options)
    end
  end

  helper Mailers::ApplicationNotificationsHelper

  def proof_approved(application, proof_review, recipient: nil)
    with_mailer_error_handling("proof_approved application=#{application&.id} proof_review=#{proof_review&.id}") do
      recipient ||= application.user
      template_name = 'application_notifications_proof_approved'
      locale = resolve_template_locale(recipient: recipient)
      text_template = find_text_template(template_name, locale: locale)
      variables = build_proof_approved_variables(application, proof_review, template: text_template, locale: locale)

      if prefers_letter_delivery?(recipient)
        queue_letter_delivery(
          recipient: recipient,
          template_name: template_name,
          variables: variables.merge(proof_type: proof_review.proof_type),
          letter_type: :proof_approved,
          application: application
        )
        return noop_letter_delivery
      end

      send_email(recipient_email_for(recipient), text_template, variables)
    end
  end

  def proof_rejected(application, proof_review, secure_upload_url: nil, recipient: nil)
    with_mailer_error_handling("proof_rejected application=#{application&.id} proof_review=#{proof_review&.id}") do
      recipient ||= application.user
      remaining_attempts   = 8 - application.total_rejections
      reapply_date         = 3.years.from_now.to_date
      template_name        = 'application_notifications_proof_rejected'
      locale               = resolve_template_locale(recipient: recipient)
      text_template        = find_text_template(template_name, locale: locale)
      variables            = build_proof_rejected_variables(
        application,
        proof_review,
        remaining_attempts,
        reapply_date,
        secure_upload_url,
        recipient,
        template: text_template,
        locale: locale
      )

      if prefers_letter_delivery?(recipient)
        queue_letter_delivery(
          recipient: recipient,
          template_name: template_name,
          variables: variables.merge(proof_type: proof_review.proof_type),
          letter_type: proof_rejection_letter_type(proof_review.proof_type),
          application: application
        )
        return noop_letter_delivery
      end

      send_proof_rejected_email(recipient, text_template, variables)
    end
  end

  def proof_requested(application, proof_type, secure_upload_url: nil, recipient: nil)
    with_mailer_error_handling("proof_requested application=#{application&.id} proof_type=#{proof_type}") do
      recipient ||= application.user
      template_name = 'application_notifications_proof_requested'
      locale = resolve_template_locale(recipient: recipient)
      text_template = find_text_template(template_name, locale: locale)
      variables = build_proof_requested_variables(
        application,
        proof_type,
        secure_upload_url,
        recipient,
        template: text_template,
        locale: locale
      )

      if prefers_letter_delivery?(recipient)
        queue_letter_delivery(
          recipient: recipient,
          template_name: template_name,
          variables: variables.merge(proof_type: proof_type),
          application: application
        )
        return noop_letter_delivery
      end

      send_email(recipient_email_for(recipient), text_template, variables)
    end
  end

  def max_rejections_reached(application)
    Rails.logger.info "Preparing max_rejections_reached email for Application ID: #{application.id}"
    Rails.logger.info "Delivery method: #{ActionMailer::Base.delivery_method}"

    with_mailer_error_handling("max_rejections_reached application=#{application&.id}",
                               raise_in_test_only: true) do
      reapply_date  = 3.years.from_now.to_date
      template_name = 'application_notifications_max_rejections_reached'
      locale        = resolve_template_locale(recipient: application.user)
      text_template = find_text_template(template_name, locale: locale)
      variables     = build_max_rejections_variables(application, reapply_date, template: text_template, locale: locale)

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

      locale        = staff_template_locale
      text_template = find_text_template('application_notifications_proof_needs_review_reminder', locale: locale)
      variables     = build_review_reminder_variables(admin, stale_reviews, template: text_template, locale: locale)

      send_email(admin.email, text_template, variables)
    end
  end

  def account_created(constituent)
    with_mailer_error_handling("account_created constituent=#{constituent&.id}") do
      return handle_nil_constituent if constituent.nil?

      template_name   = 'application_notifications_account_created'
      locale          = resolve_template_locale(recipient: constituent)
      text_template   = find_text_template(template_name, locale: locale)
      variables       = build_account_created_variables(constituent, template: text_template, locale: locale)
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

  def security_key_recovery_approved(recovery_request, notification)
    with_mailer_error_handling("security_key_recovery_approved recovery_request=#{recovery_request&.id}") do
      recipient = notification.recipient
      template_name = 'application_notifications_security_key_recovery_approved'
      locale = audience_template_locale(recipient: recipient)
      text_template = find_text_template(template_name, locale: locale)
      variables = build_security_key_recovery_approved_variables(recipient, template: text_template, locale: locale)

      send_email(recipient_email_for(recipient), text_template, variables)
    end
  end

  def income_threshold_exceeded(constituent_params, notification_params)
    with_mailer_error_handling('income_threshold_exceeded') do
      template_name = 'application_notifications_income_threshold_exceeded'
      service_result = get_income_threshold_data(constituent_params, notification_params)
      locale         = normalize_locale(service_result[:constituent][:locale]) || resolve_template_locale
      text_template  = find_text_template(template_name, locale: locale)
      variables      = build_income_threshold_variables(service_result, template: text_template, locale: locale)

      notification_pref = notification_params[:communication_preference] || notification_params['communication_preference']
      if prefers_letter_delivery?(constituent_params, override: notification_pref.presence)
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

  def registration_confirmation(user)
    with_mailer_error_handling("registration_confirmation user=#{user&.id}") do
      active_vendors_text_list = build_active_vendors_list
      template_name            = 'application_notifications_registration_confirmation'
      locale                   = resolve_template_locale(recipient: user)
      text_template            = find_text_template(template_name, locale: locale)
      variables                = build_registration_variables(user, active_vendors_text_list, template: text_template, locale: locale)

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
      template_name    = 'application_notifications_proof_received'
      locale           = resolve_template_locale(recipient: application.user)
      text_template    = find_text_template(template_name, locale: locale)
      variables        = build_proof_received_variables(application, proof_type, template: text_template, locale: locale)
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

  def medical_certification_not_provided(application, _notification = nil)
    with_mailer_error_handling("medical_certification_not_provided application=#{application&.id}") do
      template_name = 'application_notifications_medical_certification_not_provided'
      locale        = resolve_template_locale(recipient: application.user)
      text_template = find_text_template(template_name, locale: locale)
      variables     = build_medical_certification_not_provided_variables(application, template: text_template, locale: locale)

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
    end
  end

  def provider_info_requested(application, secure_request_form, secure_url: nil)
    with_mailer_error_handling("provider_info_requested application=#{application&.id} secure_request_form=#{secure_request_form&.id}") do
      template_name = 'application_notifications_provider_info_requested'
      recipient = secure_request_form.recipient
      locale = resolve_template_locale(recipient: recipient)
      text_template = find_text_template(template_name, locale: locale)
      variables = build_provider_info_requested_variables(
        application,
        secure_request_form,
        secure_url,
        template: text_template,
        locale: locale
      )

      if secure_request_form.recipient_channel_letter?
        queue_letter_delivery(
          recipient: recipient,
          template_name: template_name,
          variables: variables,
          letter_type: :provider_info_requested,
          application: application
        )
        return noop_letter_delivery
      end

      send_email(
        secure_request_form.recipient_email,
        text_template,
        variables,
        reply_to: [support_email]
      )
    end
  end

  private

  def with_mailer_error_handling(context, raise_in_test_only: false)
    yield
  rescue StandardError => e
    error_message = sanitize_secure_error_message(e.message)
    backtrace = sanitize_secure_error_message(e.backtrace&.join("\n"))
    Rails.logger.error("Mailer error (#{context}): #{error_message}\n#{backtrace}")
    raise if !raise_in_test_only || Rails.env.test?

    noop_delivery
    nil
  end

  def build_base_email_variables(template:, organization_name: nil, locale: nil, subject_variables: {})
    header_title = header_title_from_template_subject(template: template, subject_variables: subject_variables)
    org_name = organization_name || Policy.get('organization_name') || 'Maryland Accessible Telecommunications'
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = ProgramContact.website_url
    header_logo_url = safe_asset_path('logo.png')

    {
      header_text: header_text(title: header_title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(
        contact_email: footer_contact_email,
        website_url: footer_website_url,
        organization_name: org_name,
        show_automated_message: true,
        locale: locale
      ),
      header_logo_url: header_logo_url,
      header_subtitle: nil,
      support_email: footer_contact_email,
      office_address: ProgramContact.office_address,
      program_website_url: ProgramContact.website_url
    }
  end

  def safe_asset_path(asset_name)
    ActionController::Base.helpers.asset_path(asset_name, host: default_url_options[:host])
  rescue StandardError
    nil
  end

  def build_proof_approved_variables(application, proof_review, template:, locale: nil)
    user                      = application.user
    organization_name         = Policy.get('organization_name') || 'MAT Program'
    proof_type_formatted      = format_proof_type(proof_review.proof_type)
    all_proofs_approved       = application.respond_to?(:all_proofs_approved?) && application.all_proofs_approved?
    all_proofs_approved_text  = all_proofs_approved ? 'All required documents for your application have now been approved.' : ''

    base_variables = build_base_email_variables(
      template: template,
      organization_name: 'MAT Program',
      locale: locale,
      subject_variables: { proof_type_formatted: proof_type_formatted }
    )

    base_variables.merge({
                           user_first_name: user.first_name,
                           organization_name: organization_name,
                           proof_type_formatted: proof_type_formatted,
                           all_proofs_approved_message_text: all_proofs_approved_text
                         }).compact
  end

  def build_proof_rejected_variables(application, proof_review, remaining_attempts, reapply_date, secure_upload_url, recipient, template:, locale: nil) # rubocop:disable Metrics/ParameterLists
    user                 = application.user
    proof_type_formatted = format_proof_type(proof_review.proof_type)
    recipient ||= user

    base_variables = build_base_email_variables(
      template: template,
      organization_name: 'MAT Program',
      locale: locale,
      subject_variables: { proof_type_formatted: proof_type_formatted }
    )

    rejection_reason = resolve_rejection_reason(proof_review, locale)
    remaining_attempts_message = build_remaining_attempts_message(remaining_attempts, reapply_date, locale: locale)
    default_options_text = build_resubmission_options(
      application,
      secure_upload_url,
      proof_type_formatted: proof_type_formatted,
      locale: locale
    )
    archived_message = build_archived_message(reapply_date, locale: locale)

    base_variables.merge({
                           user_first_name: recipient.first_name,
                           constituent_full_name: user.full_name,
                           organization_name: 'MAT Program',
                           proof_type_formatted: proof_type_formatted,
                           rejection_reason: rejection_reason,
                           secure_upload_url: secure_upload_url,
                           remaining_attempts_message_text: remaining_attempts.positive? ? remaining_attempts_message : '',
                           default_options_text: remaining_attempts.positive? ? default_options_text : '',
                           archived_message_text: remaining_attempts.positive? ? '' : archived_message
                         }).compact
  end

  def build_proof_requested_variables(application, proof_type, secure_upload_url, recipient, template:, locale: nil)
    user = application.user
    proof_type_formatted = format_proof_type(proof_type)
    recipient ||= user

    base_variables = build_base_email_variables(
      template: template,
      organization_name: 'MAT Program',
      locale: locale,
      subject_variables: { proof_type_formatted: proof_type_formatted }
    )

    default_options_text = build_proof_submission_options(
      'application_notifications.proof_requested.submission_options',
      application,
      secure_upload_url,
      proof_type_formatted: proof_type_formatted,
      locale: locale
    )

    base_variables.merge({
                           user_first_name: recipient.first_name,
                           constituent_full_name: user.full_name,
                           organization_name: 'MAT Program',
                           proof_type_formatted: proof_type_formatted,
                           secure_upload_url: secure_upload_url,
                           default_options_text: default_options_text
                         }).compact
  end

  def resolve_rejection_reason(proof_review, locale)
    raw_reason = proof_review.rejection_reason.to_s
    reason_code = proof_review.rejection_reason_code.presence || raw_reason

    reason = rejection_reason_for_code(
      reason_code,
      proof_type: proof_review.proof_type,
      locale: locale
    )
    return interpolate_address_placeholder(reason.body, proof_review.application) if reason&.body
    return none_provided_rejection_reason(proof_review.proof_type, locale) if reason_code == 'none_provided'

    proof_review.rejection_reason
  end

  def rejection_reason_for_code(code, proof_type:, locale:)
    return nil if code.blank?

    RejectionReason.resolve(code: code, proof_type: proof_type, locale: locale)
  end

  def none_provided_rejection_reason(proof_type, locale)
    I18n.t(
      "application_notifications.proof_rejected.none_provided.#{proof_type}",
      locale: locale,
      default: I18n.t('application_notifications.proof_rejected.none_provided.default', locale: locale)
    )
  end

  def interpolate_address_placeholder(body, application)
    return body unless body.include?('%<address>s') || body.include?('%<address>')

    format(body, address: build_application_address(application))
  rescue KeyError, ArgumentError
    body
  end

  def build_application_address(application)
    user = application.user
    return '' unless user

    addr1 = user.physical_address_1.to_s
    addr2 = user.physical_address_2.presence || ''
    city = user.city.to_s
    state = user.state.to_s
    zip = user.zip_code.to_s
    "#{addr1} #{addr2} #{city}, #{state} #{zip}".squish
  end

  def build_remaining_attempts_message(remaining_attempts, reapply_date, locale: nil)
    locale = locale.presence || I18n.default_locale
    I18n.t(
      'application_notifications.proof_rejected.remaining_attempts_message',
      count: remaining_attempts,
      locale: locale,
      reapply_date: I18n.l(reapply_date, format: :long, locale: locale)
    )
  end

  def build_resubmission_options(application, secure_upload_url, proof_type_formatted:, locale: nil)
    build_proof_submission_options(
      'application_notifications.proof_rejected.resubmission_options',
      application,
      secure_upload_url,
      proof_type_formatted: proof_type_formatted,
      locale: locale
    )
  end

  def build_proof_submission_options(scope, _application, secure_upload_url, proof_type_formatted:, locale: nil)
    locale = locale.presence || I18n.default_locale
    option_type = secure_upload_url.present? ? 'online' : 'paper'

    I18n.t(
      "#{scope}.#{option_type}",
      locale: locale,
      secure_upload_url: secure_upload_url,
      proof_type_formatted: proof_type_formatted,
      office_address: ProgramContact.office_address
    ).strip
  end

  def build_archived_message(reapply_date, locale: nil)
    locale = locale.presence || I18n.default_locale
    I18n.t(
      'application_notifications.proof_rejected.archived_message',
      locale: locale,
      reapply_date: I18n.l(reapply_date, format: :long, locale: locale)
    )
  end

  def send_proof_rejected_email(user, text_template, variables)
    send_email(
      recipient_email_for(user),
      text_template,
      variables
    )
  end

  def build_max_rejections_variables(application, reapply_date, template:, locale: nil)
    base_variables = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: { application_id: application.id, reapply_date_formatted: reapply_date.strftime('%B %d, %Y') }
    )
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

  def build_review_reminder_variables(admin, stale_reviews, template:, locale: nil)
    admin_dashboard_url = admin_applications_url(host: default_url_options[:host])
    stale_reviews_text_list = build_stale_reviews_list(stale_reviews)
    base_variables = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: { stale_reviews_count: stale_reviews.count, admin_full_name: admin.full_name }
    )

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

  def build_account_created_variables(constituent, template:, locale: nil)
    header_title = header_title_from_template_subject(
      template: template,
      subject_variables: { constituent_first_name: constituent.first_name }
    )
    base_variables = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: { constituent_first_name: constituent.first_name }
    )

    variables = {
      constituent_first_name: constituent.first_name,
      header_title: header_title,
      footer_contact_email: Policy.get('support_email') || 'mat.program1@maryland.gov',
      footer_website_url: ProgramContact.website_url,
      program_website_url: ProgramContact.website_url,
      footer_show_automated_message: true
    }

    base_variables.merge(variables).compact
  end

  def build_security_key_recovery_approved_variables(user, template:, locale: nil)
    base_variables = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: { user_first_name: user.first_name }
    )

    base_variables.merge({
                           user_first_name: user.first_name,
                           sign_in_url: sign_in_url(host: default_url_options[:host])
                         }).compact
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

  def build_income_threshold_variables(service_result, template:, locale: nil)
    constituent    = service_result[:constituent]
    notification   = service_result[:notification]
    threshold_data = service_result[:threshold_data]
    threshold      = service_result[:threshold]

    status_box_title   = 'Application Status: Income Threshold Exceeded'
    status_box_message = "Based on the information provided, your household income exceeds the program's limit."
    base_variables     = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: { constituent_first_name: constituent[:first_name] }
    )

    base_variables.merge({
                           constituent_first_name: constituent[:first_name],
                           household_size: threshold_data[:household_size],
                           annual_income_formatted: ActionController::Base.helpers.number_to_currency(notification[:annual_income]),
                           threshold_formatted: ActionController::Base.helpers.number_to_currency(threshold),
                           status_box_text: status_box_text(status: 'error', title: status_box_title, message: status_box_message),
                           additional_notes: notification[:additional_notes]
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

  def build_registration_variables(user, active_vendors_text_list, template:, locale: nil)
    organization_name = Policy.get('organization_name') || 'Maryland Accessible Telecommunications'
    base_variables    = build_base_email_variables(
      template: template,
      organization_name: organization_name,
      locale: locale,
      subject_variables: { user_full_name: user.full_name, user_first_name: user.first_name }
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

  def build_application_submitted_variables(application, template:, locale: nil)
    base_variables = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: {
        application_id: application.id,
        submission_date_formatted: application.application_date&.strftime('%B %d, %Y') || Time.current.strftime('%B %d, %Y')
      }
    )

    variables = {
      user_first_name: application.user.first_name,
      application_id: application.id,
      submission_date_formatted: application.application_date&.strftime('%B %d, %Y') || Time.current.strftime('%B %d, %Y')
    }

    base_variables.merge(variables).compact
  end

  def build_training_requested_variables(application, notification, template:, locale: nil)
    admin = notification.recipient
    constituent = notification.actor || application.user
    request_date = application.training_requested_at || Time.current
    base_variables = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: {
        application_id: application.id,
        constituent_full_name: constituent.full_name
      }
    )

    variables = {
      admin_full_name: admin.full_name,
      constituent_full_name: constituent.full_name,
      application_id: application.id,
      request_date_formatted: I18n.l(request_date.to_date, format: :long, locale: locale),
      admin_application_url: admin_application_url(application, host: default_url_options[:host])
    }

    base_variables.merge(variables).compact
  end

  # --- Proof received ---

  def build_proof_received_variables(application, proof_type, template:, locale: nil)
    user                 = application.user
    organization_name    = Policy.get('organization_name') || 'MAT Program'
    proof_type_formatted = format_proof_type(proof_type)
    base_variables       = build_base_email_variables(
      template: template,
      organization_name: organization_name,
      locale: locale,
      subject_variables: { proof_type_formatted: proof_type_formatted }
    )

    base_variables.merge({
                           user_first_name: user.first_name,
                           organization_name: organization_name,
                           proof_type_formatted: proof_type_formatted
                         }).compact
  end

  # Medical certification not provided specific methods
  def build_medical_certification_not_provided_variables(application, template:, locale: nil)
    user = application.user

    rejection_reason_message = application.medical_certification_rejection_reason.presence || ''

    base_variables = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: {
        user_first_name: user.first_name,
        application_id: application.id
      }
    )
    cert_variables = {
      user_first_name: user.first_name,
      rejection_reason_message: rejection_reason_message,
      application_id: application.id
    }

    base_variables.merge(cert_variables).compact
  end

  def build_provider_info_requested_variables(application, secure_request_form, secure_url, template:, locale: nil)
    recipient = secure_request_form.recipient
    base_variables = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: {
        user_first_name: recipient.first_name,
        application_id: application.id
      }
    )
    instructions_key = secure_url.present? ? :email_instructions : :letter_instructions

    base_variables.merge({
                           user_first_name: recipient.first_name,
                           constituent_first_name: application.user.first_name,
                           constituent_name: application.constituent_full_name,
                           application_id: application.id,
                           secure_url: secure_url,
                           expiration_hours: Policy.get('secure_form_link_expiration_hours') || 48,
                           support_email: support_email,
                           support_phone: support_phone,
                           provider_info_instructions: I18n.t(
                             "application_notifications.provider_info_requested.#{instructions_key}",
                             locale: locale,
                             secure_url: secure_url,
                             support_email: support_email,
                             support_phone: support_phone,
                             hours: Policy.get('secure_form_link_expiration_hours') || 48
                           )
                         }).compact
  end

  def proof_rejection_letter_type(proof_type)
    case proof_type.to_s
    when 'income'
      :income_proof_rejected
    when 'residency'
      :residency_proof_rejected
    when 'id'
      :id_proof_rejected
    else
      :other_notification
    end
  end

  def support_email
    Policy.get('support_email') || 'mat.program1@maryland.gov'
  end

  def support_phone
    '410-767-6960'
  end
end
