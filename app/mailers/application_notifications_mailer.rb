# frozen_string_literal: true

class ApplicationNotificationsMailer < ApplicationMailer # rubocop:disable Metrics/ClassLength
  layout false
  include Mailers::ApplicationNotificationsHelper

  def application_submitted(application)
    @application = application
    @user = application.user

    with_mailer_error_handling("application_submitted application=#{application&.id}") do
      template_name = 'application_notifications_application_submitted'
      locale        = resolve_template_locale(recipient: @user)
      text_template = find_text_template(template_name, locale: locale)
      variables     = build_application_submitted_variables(application, template: text_template, locale: locale)
      mail_options = { message_stream: 'notifications' }

      return noop_letter_delivery if queue_letter_if_preferred(
        @user, template_name, variables,
        locale: locale, application: application
      )

      send_email(recipient_email_for(@user), text_template, variables, mail_options)
    end
  end

  def training_requested(application, notification)
    with_mailer_error_handling("training_requested application=#{application&.id} notification=#{notification&.id}") do
      admin = notification.recipient
      trainer_audience = notification.metadata['recipient_audience'] == 'assigned_trainer'
      if trainer_audience && !application.current_trainer?(admin)
        EmailDelivery::Outcome.record_not_sent(EmailDelivery::Decision.suppressed(:trainer_coverage_changed),
                                               context: @delivery_context, mail_action: 'ApplicationNotificationsMailer#training_requested')
        return noop_delivery(channel: :email, reason: 'trainer_coverage_changed')
      end
      template_name = 'application_notifications_training_requested'
      locale = trainer_audience ? resolve_template_locale(recipient: admin) : 'en'
      text_template = find_text_template(template_name, locale: locale)
      variables     = build_training_requested_variables(
        application,
        notification,
        template: text_template,
        locale: locale
      )
      mail_options = { message_stream: 'notifications' }

      return noop_letter_delivery if queue_letter_if_preferred(
        admin, template_name, variables,
        locale: locale, application: application
      )

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

      return noop_letter_delivery if queue_letter_if_preferred(
        recipient, template_name, variables.merge(proof_type: proof_review.proof_type),
        locale: locale, letter_type: :proof_approved, application: application
      )

      send_email(recipient_email_for(recipient), text_template, variables)
    end
  end

  # The form's channel and encrypted contact snapshot override current recipient preferences.
  # Email uses the snapshot address. Letters use the resolver-selected letter_recipient.
  # Without a form, legacy preference routing applies.
  def proof_rejected(application, proof_review, secure_upload_url: nil, recipient: nil, secure_request_form: nil,
                     letter_recipient: nil)
    with_mailer_error_handling("proof_rejected application=#{application&.id} proof_review=#{proof_review&.id}") do
      recipient ||= application.user
      template_name        = 'application_notifications_proof_rejected'
      locale               = secure_request_locale(secure_request_form, recipient)
      text_template        = find_text_template(template_name, locale: locale)
      variables            = build_proof_rejected_variables(
        application,
        proof_review,
        secure_upload_url,
        recipient,
        template: text_template,
        locale: locale
      )
      letter_type = DocumentType.fetch(proof_review.proof_type).rejection_letter_type

      if secure_request_form.present?
        if secure_request_form.recipient_channel_letter?
          queue_letter_delivery(
            locale: locale,
            recipient: recipient,
            template_name: template_name,
            variables: variables.merge(proof_type: proof_review.proof_type),
            letter_type: letter_type,
            application: application,
            print_recipient: letter_recipient,
            secure_request_form: secure_request_form
          )
          return noop_letter_delivery
        end

        return send_email(secure_request_form.recipient_email, text_template, variables, required_delivery: true)
      end

      return noop_letter_delivery if queue_letter_if_preferred(
        recipient, template_name, variables.merge(proof_type: proof_review.proof_type),
        locale: locale, letter_type: letter_type, application: application
      )

      send_proof_rejected_email(recipient, text_template, variables)
    end
  end

  # Channel/snapshot/address-owner contract is identical to proof_rejected.
  def proof_requested(application, proof_type, secure_upload_url: nil, recipient: nil, secure_request_form: nil,
                      letter_recipient: nil)
    with_mailer_error_handling("proof_requested application=#{application&.id} proof_type=#{proof_type}") do
      recipient ||= application.user
      template_name = 'application_notifications_proof_requested'
      locale = secure_request_locale(secure_request_form, recipient)
      text_template = find_text_template(template_name, locale: locale)
      variables = build_proof_requested_variables(
        application,
        proof_type,
        secure_upload_url,
        recipient,
        template: text_template,
        locale: locale
      )

      if secure_request_form.present?
        if secure_request_form.recipient_channel_letter?
          queue_letter_delivery(
            locale: locale,
            recipient: recipient,
            template_name: template_name,
            variables: variables.merge(proof_type: proof_type),
            application: application,
            print_recipient: letter_recipient,
            secure_request_form: secure_request_form
          )
          return noop_letter_delivery
        end

        return send_email(secure_request_form.recipient_email, text_template, variables, required_delivery: true)
      end

      return noop_letter_delivery if queue_letter_if_preferred(
        recipient, template_name, variables.merge(proof_type: proof_type),
        locale: locale, application: application
      )

      send_email(recipient_email_for(recipient), text_template, variables)
    end
  end

  def max_rejections_reached(application)
    Rails.logger.info "Preparing max_rejections_reached email for Application ID: #{application.id}"
    Rails.logger.info "Delivery method: #{ActionMailer::Base.delivery_method}"

    with_mailer_error_handling("max_rejections_reached application=#{application&.id}",
                               swallow_errors: true) do
      template_name = 'application_notifications_max_rejections_reached'
      locale        = resolve_template_locale(recipient: application.user)
      text_template = find_text_template(template_name, locale: locale)
      variables     = build_max_rejections_variables(application, template: text_template, locale: locale)

      return noop_letter_delivery if queue_letter_if_preferred(
        application.user, template_name, variables,
        locale: locale, letter_type: :max_rejections_reached, application: application
      )

      send_email(recipient_email_for(application.user), text_template, variables)
    end
  end

  def proof_needs_review_reminder(admin, applications)
    with_mailer_error_handling("proof_needs_review_reminder admin=#{admin&.id}",
                               swallow_errors: true) do
      stale_reviews = filter_stale_reviews(applications)

      return handle_no_stale_reviews if stale_reviews.empty?

      # Staff-only seed content is maintained only in English.
      locale        = 'en'
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

      return noop_letter_delivery if queue_letter_if_preferred(
        constituent, template_name, variables,
        locale: locale, letter_type: :account_created
      )

      send_email(recipient_email, text_template, variables)
    end
  end

  def security_key_recovery_approved(recovery_request, notification)
    with_mailer_error_handling("security_key_recovery_approved recovery_request=#{recovery_request&.id}") do
      recipient = notification.recipient
      template_name = 'application_notifications_security_key_recovery_approved'
      locale = resolve_template_locale(recipient: recipient)
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
      return noop_letter_delivery if queue_letter_if_preferred(
        constituent_params, template_name, variables,
        locale: locale, letter_type: :income_threshold_exceeded, override: notification_pref.presence
      )

      send_email(service_result[:constituent][:email], text_template, variables)
    end
  end

  def registration_confirmation(user)
    with_mailer_error_handling("registration_confirmation user=#{user&.id}") do
      template_name            = 'application_notifications_registration_confirmation'
      locale                   = resolve_template_locale(recipient: user)
      active_vendors_text_list = build_active_vendors_list(locale: locale)
      text_template            = find_text_template(template_name, locale: locale)
      variables                = build_registration_variables(user, active_vendors_text_list, template: text_template, locale: locale)

      return noop_letter_delivery if queue_letter_if_preferred(
        user, template_name, variables,
        locale: locale, letter_type: :registration_confirmation
      )

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

      return noop_letter_delivery if queue_letter_if_preferred(
        application.user, template_name, variables.merge(proof_type: proof_type),
        locale: locale, application: application
      )

      send_email(recipient_email_for(application.user), text_template, variables, { subject_override: subject_override })
    end
  end

  def disability_certification_not_provided(application, _notification = nil)
    with_mailer_error_handling("disability_certification_not_provided application=#{application&.id}") do
      template_name = 'application_notifications_disability_certification_not_provided'
      locale        = resolve_template_locale(recipient: application.user)
      text_template = find_text_template(template_name, locale: locale)
      variables     = build_disability_certification_not_provided_variables(application, template: text_template, locale: locale)

      return noop_letter_delivery if queue_letter_if_preferred(
        application.user, template_name, variables,
        locale: locale, application: application
      )

      send_email(recipient_email_for(application.user), text_template, variables)
    end
  end

  # The resolver-selected letter_recipient overrides the legacy dependent-to-guardian address owner.
  def provider_info_requested(application, secure_request_form, secure_url: nil, letter_recipient: nil)
    with_mailer_error_handling("provider_info_requested application=#{application&.id} secure_request_form=#{secure_request_form&.id}") do
      template_name = 'application_notifications_provider_info_requested'
      recipient = secure_request_form.recipient
      locale = secure_request_locale(secure_request_form, recipient)
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
          locale: locale,
          recipient: recipient,
          template_name: template_name,
          variables: variables,
          letter_type: :provider_info_requested,
          application: application,
          print_recipient: letter_recipient,
          secure_request_form: secure_request_form
        )
        return noop_letter_delivery
      end

      send_email(
        secure_request_form.recipient_email,
        text_template,
        variables,
        reply_to: [ProgramContact.support_email],
        required_delivery: true
      )
    end
  end

  private

  def with_mailer_error_handling(context, swallow_errors: false)
    yield
  rescue StandardError => e
    Rails.logger.error("Mailer error (#{context}): #{e.class.name}")
    raise unless swallow_errors

    nil
  end

  def build_base_email_variables(template:, organization_name: nil, locale: nil, subject_variables: {})
    envelope_variables(template: template, locale: locale, subject_variables: subject_variables,
                       organization_name: organization_name || Policy.get('organization_name') || 'Maryland Accessible Telecommunications')
      .merge(header_subtitle: nil, office_address: ProgramContact.office_address, program_website_url: ProgramContact.website_url)
  end

  def build_proof_approved_variables(application, proof_review, template:, locale: nil)
    user                      = application.user
    organization_name         = Policy.get('organization_name') || 'MAT Program'
    proof_type_formatted      = format_proof_type(proof_review.proof_type, locale: locale)
    all_proofs_approved       = application.respond_to?(:all_proofs_approved?) && application.all_proofs_approved?
    all_proofs_approved_text  = all_proofs_approved ? I18n.t('application_notifications.proof_approved.all_proofs_approved', locale: locale) : ''

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

  def build_proof_rejected_variables(application, proof_review, secure_upload_url, recipient, template:, locale: nil)
    user                 = application.user
    remaining_attempts   = 8 - application.total_rejections
    proof_type_formatted = format_proof_type(proof_review.proof_type, locale: locale)
    recipient ||= user

    base_variables = build_base_email_variables(
      template: template,
      organization_name: 'MAT Program',
      locale: locale,
      subject_variables: { proof_type_formatted: proof_type_formatted }
    )

    rejection_reason = resolve_rejection_reason(proof_review, locale)
    remaining_attempts_message = build_remaining_attempts_message(remaining_attempts, locale: locale)
    default_options_text = build_resubmission_options(
      application,
      secure_upload_url,
      proof_type_formatted: proof_type_formatted,
      locale: locale
    )
    archived_message = build_archived_message(locale: locale)

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
    proof_type_formatted = format_proof_type(proof_type, locale: locale)
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
    return reason.body_for(proof_review.application) if reason&.body
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

  def build_remaining_attempts_message(remaining_attempts, locale: nil)
    locale = locale.presence || I18n.default_locale
    I18n.t(
      'application_notifications.proof_rejected.remaining_attempts_message',
      count: remaining_attempts,
      locale: locale
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

  def build_archived_message(locale: nil)
    locale = locale.presence || I18n.default_locale
    I18n.t(
      'application_notifications.proof_rejected.archived_message',
      locale: locale
    )
  end

  def send_proof_rejected_email(user, text_template, variables)
    send_email(
      recipient_email_for(user),
      text_template,
      variables
    )
  end

  def build_max_rejections_variables(application, template:, locale: nil)
    base_variables = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: { application_id: application.id }
    )
    base_variables.merge({
                           user_first_name: application.user.first_name,
                           application_id: application.id
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

  def handle_nil_constituent
    Rails.logger.error('[DATA_INTEGRITY] ApplicationNotificationsMailer#account_created called with nil constituent')
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
      footer_contact_email: ProgramContact.support_email,
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
                           sign_in_url: sign_in_url(**CanonicalPublicUrlOptions.call)
                         }).compact
  end

  def extract_recipient_email(constituent)
    return constituent[:email] if constituent.is_a?(Hash)

    recipient_email_for(constituent)
  end

  def get_income_threshold_data(constituent_params, notification_params)
    result = Notifications::IncomeThresholdService.call(constituent_params, notification_params)

    unless result.success?
      constituent_id = constituent_params.is_a?(Hash) ? constituent_params[:id] : constituent_params&.id
      Rails.logger.error("Failed to prepare income threshold data for constituent #{constituent_id}")
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

  def build_active_vendors_list(locale: nil)
    active_vendors = Users::Vendor.active.order(:business_name)
    if active_vendors.any?
      active_vendors.map { |v| "- #{v.business_name}" }.join("\n")
    else
      I18n.t('application_notifications.registration_confirmation.no_active_vendors', locale: locale)
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
    constituent = application.user
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
      admin_application_url: training_request_destination(application, notification)
    }

    base_variables.merge(variables).compact
  end

  def training_request_destination(application, notification)
    if notification.metadata['recipient_audience'] == 'assigned_trainer'
      trainers_training_session_url(application.latest_training_session, host: default_url_options[:host])
    else
      admin_application_url(application, host: default_url_options[:host])
    end
  end

  def build_proof_received_variables(application, proof_type, template:, locale: nil)
    user                 = application.user
    organization_name    = Policy.get('organization_name') || 'MAT Program'
    proof_type_formatted = format_proof_type(proof_type, locale: locale)
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

  def build_disability_certification_not_provided_variables(application, template:, locale: nil)
    user = application.user

    review = application.latest_disability_certification_rejection_review
    rejection_reason_message = review ? resolve_rejection_reason(review, locale) : ''

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
                           expiration_hours: SecureFormPolicy.link_expiration_hours,
                           support_email: ProgramContact.support_email,
                           support_phone: ProgramContact.support_phone,
                           provider_info_instructions: I18n.t(
                             "application_notifications.provider_info_requested.#{instructions_key}",
                             locale: locale,
                             secure_url: secure_url,
                             support_email: ProgramContact.support_email,
                             support_phone: ProgramContact.support_phone,
                             hours: SecureFormPolicy.link_expiration_hours
                           )
                         }).compact
  end
end
