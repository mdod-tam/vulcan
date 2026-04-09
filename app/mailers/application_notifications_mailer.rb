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
      locale        = resolve_template_locale(recipient: @user)
      text_template = find_text_template(template_name, locale: locale)
      variables     = build_application_submitted_variables(application, template: text_template, locale: locale)
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
      locale = resolve_template_locale(recipient: application.user)
      text_template = find_text_template(template_name, locale: locale)
      variables = build_proof_approved_variables(application, proof_review, template: text_template, locale: locale)

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
      locale               = resolve_template_locale(recipient: application.user)
      text_template        = find_text_template(template_name, locale: locale)
      variables            = build_proof_rejected_variables(
        application,
        proof_review,
        remaining_attempts,
        reapply_date,
        template: text_template,
        locale: locale
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

      locale        = resolve_template_locale(recipient: admin)
      text_template = find_text_template('application_notifications_proof_needs_review_reminder', locale: locale)
      variables     = build_review_reminder_variables(admin, stale_reviews, template: text_template, locale: locale)

      send_email(admin.email, text_template, variables)
    end
  end

  def account_created(constituent, temp_password)
    with_mailer_error_handling("account_created constituent=#{constituent&.id}") do
      return handle_nil_constituent if constituent.nil?

      template_name   = 'application_notifications_account_created'
      locale          = resolve_template_locale(recipient: constituent)
      text_template   = find_text_template(template_name, locale: locale)
      variables       = build_account_created_variables(constituent, temp_password, template: text_template, locale: locale)
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

  def proof_submission_error(constituent, application, _error_type, message)
    with_mailer_error_handling("proof_submission_error constituent=#{constituent&.id} application=#{application&.id}") do
      recipient_info = determine_proof_error_recipient(constituent, message)
      template_name  = 'application_notifications_proof_submission_error'
      locale         = resolve_template_locale(recipient: constituent)
      text_template  = find_text_template(template_name, locale: locale)
      variables      = build_proof_error_variables(recipient_info[:full_name], message, template: text_template, locale: locale)

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

  private

  def with_mailer_error_handling(context, raise_in_test_only: false)
    yield
  rescue StandardError => e
    Rails.logger.error("Mailer error (#{context}): #{e.message}\n#{e.backtrace.join("\n")}")
    raise if !raise_in_test_only || Rails.env.test?

    noop_delivery
    nil
  end

  def build_base_email_variables(template:, organization_name: nil, locale: nil, subject_variables: {})
    header_title = header_title_from_template_subject(template: template, subject_variables: subject_variables)
    org_name = organization_name || Policy.get('organization_name') || 'Maryland Accessible Telecommunications'
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = root_url(host: default_url_options[:host])
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
      support_email: footer_contact_email
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

  def build_proof_rejected_variables(application, proof_review, remaining_attempts, reapply_date, template:, locale: nil)
    user                 = application.user
    proof_type_formatted = format_proof_type(proof_review.proof_type)
    sign_in_url          = sign_in_url(host: default_url_options[:host])

    base_variables = build_base_email_variables(
      template: template,
      organization_name: 'MAT Program',
      locale: locale,
      subject_variables: { proof_type_formatted: proof_type_formatted }
    )

    rejection_reason = resolve_rejection_reason(proof_review, locale)
    remaining_attempts_message = build_remaining_attempts_message(remaining_attempts, reapply_date)
    default_options_text = build_resubmission_options(application, sign_in_url)
    archived_message = build_archived_message(reapply_date)

    base_variables.merge({
                           user_first_name: user.first_name,
                           constituent_full_name: user.full_name,
                           organization_name: 'MAT Program',
                           proof_type_formatted: proof_type_formatted,
                           rejection_reason: rejection_reason,
                           sign_in_url: sign_in_url,
                           remaining_attempts_message_text: remaining_attempts.positive? ? remaining_attempts_message : '',
                           default_options_text: remaining_attempts.positive? ? default_options_text : '',
                           archived_message_text: remaining_attempts.positive? ? '' : archived_message
                         }).compact
  end

  def resolve_rejection_reason(proof_review, locale)
    return proof_review.rejection_reason if proof_review.rejection_reason_code.blank?

    reason = RejectionReason.resolve(
      code: proof_review.rejection_reason_code,
      proof_type: proof_review.proof_type,
      locale: locale
    )
    return proof_review.rejection_reason unless reason&.body

    interpolate_address_placeholder(reason.body, proof_review.application)
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

  def build_remaining_attempts_message(remaining_attempts, reapply_date)
    "You have #{remaining_attempts} #{'attempt'.pluralize(remaining_attempts)} remaining to submit the required documentation before #{reapply_date.strftime('%B %d, %Y')}."
  end

  def build_resubmission_options(application, sign_in_url)
    if application.submission_method_paper?
      <<~TEXT.strip
        HOW TO RESUBMIT YOUR DOCUMENTATION:
        1. Reply to this email: Simply reply to this email and attach your updated documentation.
        2. Mail it to us: You can mail copies of your documents to our office, and we will scan and upload them for you:
           Maryland Accessible Telecommunications
           123 Main Street
           Baltimore, MD 21201
      TEXT
    else
      <<~TEXT.strip
        HOW TO RESUBMIT YOUR DOCUMENTATION:
        1. Reply to this email: Simply reply to this email and attach your updated documentation.
        2. Upload Online: Sign in to your account dashboard at #{sign_in_url} and upload your new documents securely.
        3. Mail it to us: You can mail copies of your documents to our office, and we will scan and upload them for you:
           Maryland Accessible Telecommunications
           123 Main Street
           Baltimore, MD 21201
      TEXT
    end
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

  def build_account_created_variables(constituent, temp_password, template:, locale: nil)
    header_title = header_title_from_template_subject(
      template: template,
      subject_variables: { constituent_first_name: constituent.first_name }
    )
    base_variables = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: { constituent_first_name: constituent.first_name }
    )

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

  def build_proof_error_variables(constituent_full_name, message, template:, locale: nil)
    base_variables = build_base_email_variables(
      template: template,
      locale: locale,
      subject_variables: { constituent_full_name: constituent_full_name, message: message }
    )

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
      submission_date_formatted: application.application_date&.strftime('%B %d, %Y') || Time.current.strftime('%B %d, %Y'),
      sign_in_url: sign_in_url(host: default_url_options[:host])
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
