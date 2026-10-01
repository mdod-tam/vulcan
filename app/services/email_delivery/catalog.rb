# frozen_string_literal: true

module EmailDelivery
  # Every email the application can send, and every notification action that may lead to one.
  # A mailer action missing here is blocked at delivery and fails the catalog coverage test.
  #
  # Routing:
  #   :email_only  never prints; policy can stop it before it is queued
  #   :preference  the action may print a letter instead, so only the final check stops email
  #   :email       email, reported without the email_only route reason
  module Catalog
    CATEGORIES = %w[
      proof registration voucher vendor certification training evaluation account_security application
    ].freeze

    MailAction = Data.define(:key, :category, :routing, :template, :owner, :essential) do
      def email_only? = routing == :email_only
    end

    # Notification action => how NotificationService delivers it. adapter names the argument
    # shape NotificationService builds; audit_only actions record a notification and send nothing.
    NotificationAction = Data.define(:action, :mail_action, :adapter, :routing, :owner) do
      def audit_only? = mail_action.nil?
    end

    ESSENTIAL_ACTIONS = {
      'UserMailer#password_reset' => :recovery,
      'ApplicationNotificationsMailer#security_key_recovery_approved' => :recovery,
      'SmsService#account_access' => :recovery,
      'TwoFactor#sms_login' => :sms_only_login
    }.freeze

    def self.required_account_access?(action) = mail_action(action)&.essential.present?

    PROOF_REVIEW_OWNER = 'Applications::RequestProofResubmission'
    W9_REQUEST_OWNER = 'Vendors::RequestW9Resubmission'

    # [category, routing, template, owner]
    MAIL_ACTIONS = {
      'AdminTestMailer#test_email' => [:from_test_template, :email_only, nil, 'Admin::EmailTemplatesController'],
      'ApplicationNotificationsMailer#account_created' => [:registration, :preference, 'application_notifications_account_created'],
      'ApplicationNotificationsMailer#application_submitted' => [:application, :preference, 'application_notifications_application_submitted'],
      'ApplicationNotificationsMailer#income_threshold_exceeded' => [:application, :preference, 'application_notifications_income_threshold_exceeded'],
      'ApplicationNotificationsMailer#max_rejections_reached' => [:proof, :preference, 'application_notifications_max_rejections_reached'],
      'ApplicationNotificationsMailer#medical_certification_not_provided' => [:certification, :preference,
                                                                              'application_notifications_medical_certification_not_provided'],
      'ApplicationNotificationsMailer#proof_approved' => [:proof, :preference, 'application_notifications_proof_approved'],
      'ApplicationNotificationsMailer#proof_needs_review_reminder' => [:proof, :email_only, 'application_notifications_proof_needs_review_reminder'],
      'ApplicationNotificationsMailer#proof_received' => [:proof, :preference, 'application_notifications_proof_received'],
      'ApplicationNotificationsMailer#proof_rejected' => [:proof, :preference, 'application_notifications_proof_rejected', PROOF_REVIEW_OWNER],
      'ApplicationNotificationsMailer#proof_requested' => [:proof, :preference, 'application_notifications_proof_requested', PROOF_REVIEW_OWNER],
      'ApplicationNotificationsMailer#provider_info_requested' => [:certification, :preference, 'application_notifications_provider_info_requested',
                                                                   'Applications::RequestProviderInfo'],
      'ApplicationNotificationsMailer#registration_confirmation' => [:registration, :preference, 'application_notifications_registration_confirmation'],
      'ApplicationNotificationsMailer#security_key_recovery_approved' => [:account_security, :email_only,
                                                                          'application_notifications_security_key_recovery_approved'],
      'ApplicationNotificationsMailer#training_requested' => [:training, :preference, 'application_notifications_training_requested'],
      'EvaluatorMailer#evaluation_submission_confirmation' => [:evaluation, :preference, 'evaluator_mailer_evaluation_submission_confirmation'],
      'EvaluatorMailer#new_evaluation_assigned' => [:evaluation, :email_only, 'evaluator_mailer_new_evaluation_assigned'],
      'MedicalProviderMailer#approved' => [:certification, :email_only, 'medical_provider_certification_approved'],
      'MedicalProviderMailer#certification_approved' => [:certification, :email_only, 'medical_provider_certification_approved'],
      'MedicalProviderMailer#certification_rejected' => [:certification, :email_only, 'medical_provider_certification_rejected'],
      'MedicalProviderMailer#request_certification' => [:certification, :email_only, 'medical_provider_request_certification'],
      'MedicalProviderMailer#requested' => [:certification, :email_only, 'medical_provider_request_certification'],
      'TrainingSessionNotificationsMailer#no_show_notification' => [:training, :preference, 'training_session_notifications_training_no_show'],
      'TrainingSessionNotificationsMailer#trainer_assigned' => [:training, :email_only, 'training_session_notifications_trainer_assigned'],
      'TrainingSessionNotificationsMailer#training_cancelled' => [:training, :preference, 'training_session_notifications_training_cancelled'],
      'TrainingSessionNotificationsMailer#training_rescheduled' => [:training, :preference, 'training_session_notifications_training_rescheduled'],
      'TrainingSessionNotificationsMailer#training_scheduled' => [:training, :preference, 'training_session_notifications_training_scheduled'],
      'UserMailer#password_reset' => [:account_security, :email_only, 'user_mailer_password_reset'],
      'VendorNotificationsMailer#invoice_generated' => [:vendor, :email_only, 'vendor_notifications_invoice_generated'],
      'VendorNotificationsMailer#payment_issued' => [:vendor, :email_only, 'vendor_notifications_payment_issued'],
      'VendorNotificationsMailer#w9_approved' => [:vendor, :email_only, 'vendor_notifications_w9_approved'],
      'VendorNotificationsMailer#w9_expired' => [:vendor, :email_only, 'vendor_notifications_w9_expired'],
      'VendorNotificationsMailer#w9_expiring_soon' => [:vendor, :email_only, 'vendor_notifications_w9_expiring_soon'],
      'VendorNotificationsMailer#w9_rejected' => [:vendor, :email_only, 'vendor_notifications_w9_rejected', W9_REQUEST_OWNER],
      'VendorNotificationsMailer#w9_upload_requested' => [:vendor, :email_only, nil, W9_REQUEST_OWNER],
      'VoucherNotificationsMailer#voucher_assigned' => [:voucher, :preference, 'voucher_notifications_voucher_assigned'],
      'VoucherNotificationsMailer#voucher_expired' => [:voucher, :preference, 'voucher_notifications_voucher_expired'],
      'VoucherNotificationsMailer#voucher_expiring_soon' => [:voucher, :preference, 'voucher_notifications_voucher_expiring_soon'],
      'VoucherNotificationsMailer#voucher_redeemed' => [:voucher, :preference, 'voucher_notifications_voucher_redeemed'],
      # Sent by DocuSeal, not Action Mailer; DocumentSigning::SubmissionService consults the policy.
      'DocuSeal#signing_request' => [:certification, :email_only, nil, 'DocumentSigning::SubmissionService']
    }.to_h do |key, (category, routing, template, owner)|
      [key, MailAction.new(key: key, category: category.to_s, routing: routing, template: template, owner: owner, essential: ESSENTIAL_ACTIONS[key])]
    end.freeze

    # Provider/letter entrypoints share classification with mailers, but are not mailer methods.
    PROVIDER_ACTIONS = {
      'SmsService#account_access' => [:account_security, :sms, nil, 'PasswordsController'],
      'SmsService#proof_resubmission' => [:proof, :sms, nil, PROOF_REVIEW_OWNER],
      'SmsService#provider_info' => [:certification, :sms, nil, 'Applications::RequestProviderInfo'],
      'TwoFactor#sms_login' => [:account_security, :sms, nil, 'TwoFactor::SmsLoginChallenge'],
      'TwoFactor#sms_setup' => [:account_security, :sms, nil, 'TwoFactor::PendingSmsSetupChallenge'],
      'FaxService#certification_rejected' => [:certification, :fax, nil, 'MedicalProviderNotifier'],
      'Letters#medical_certification_form' => [:certification, :letter, nil, 'Applications::MedicalCertificationPdfService']
    }.to_h do |key, (category, routing, template, owner)|
      [key, MailAction.new(key: key, category: category.to_s, routing: routing, template: template, owner: owner, essential: ESSENTIAL_ACTIONS[key])]
    end.freeze

    PROOF_REJECTION = ['ApplicationNotificationsMailer#proof_rejected', :proof_review, :preference, PROOF_REVIEW_OWNER].freeze
    PROOF_ATTACHED = ['ApplicationNotificationsMailer#proof_received', :proof_attached, :preference].freeze
    AUDIT_ONLY = [nil, nil, nil].freeze

    # [mail_action, adapter, routing, owner]
    NOTIFICATION_ACTIONS = {
      'proof_rejected' => PROOF_REJECTION,
      'id_proof_rejected' => PROOF_REJECTION,
      'income_proof_rejected' => PROOF_REJECTION,
      'residency_proof_rejected' => PROOF_REJECTION,
      'account_created' => ['ApplicationNotificationsMailer#account_created', :recipient, :preference],
      'id_proof_attached' => PROOF_ATTACHED,
      'income_proof_attached' => PROOF_ATTACHED,
      'residency_proof_attached' => PROOF_ATTACHED,
      'w9_approved' => ['VendorNotificationsMailer#w9_approved', :vendor_params, :email],
      'training_requested' => ['ApplicationNotificationsMailer#training_requested', :notifiable_and_notification, :preference],
      'trainer_assigned' => ['TrainingSessionNotificationsMailer#trainer_assigned', :notifiable, :preference],
      'training_scheduled' => ['TrainingSessionNotificationsMailer#training_scheduled', :notifiable, :preference],
      'training_rescheduled' => ['TrainingSessionNotificationsMailer#training_rescheduled', :notifiable_and_notification, :preference],
      'training_cancelled' => ['TrainingSessionNotificationsMailer#training_cancelled', :notifiable, :preference],
      'training_missed' => ['TrainingSessionNotificationsMailer#no_show_notification', :notifiable, :preference],
      'security_key_recovery_approved' => ['ApplicationNotificationsMailer#security_key_recovery_approved', :notifiable_and_notification,
                                           :email_only],
      'medical_certification_requested' => ['MedicalProviderMailer#requested', :notifiable_and_notification, :email],
      'medical_certification_not_provided' => ['ApplicationNotificationsMailer#medical_certification_not_provided',
                                               :notifiable_and_notification, :preference],
      'max_rejections_warning' => ['ApplicationNotificationsMailer#max_rejections_reached', :notifiable, :email],
      'medical_certification_received' => AUDIT_ONLY,
      'documents_requested' => AUDIT_ONLY,
      'proof_approved' => AUDIT_ONLY,
      'medical_certification_approved' => AUDIT_ONLY,
      # The rejection email needs a secure upload link, so only Vendors::RequestW9Resubmission sends it.
      'w9_rejected' => AUDIT_ONLY
    }.to_h do |action, (mail_action, adapter, routing, owner)|
      [action, NotificationAction.new(action: action, mail_action: mail_action, adapter: adapter, routing: routing, owner: owner)]
    end.freeze

    # Public methods that Action Mailer lists as actions only because a helper module was included.
    HELPER_MODULES = %w[
      SecureErrorSanitizer
      ActionView::Helpers::NumberHelper
      ConstituentCommunicationLabelsHelper
      Mailers::ApplicationNotificationsHelper
    ].freeze

    # Mailers that are not application senders.
    NON_SENDING_MAILERS = %w[ApplicationMailer PostmarkRails::TemplatedMailer].freeze

    module_function

    def mail_action(key)
      MAIL_ACTIONS[key.to_s] || PROVIDER_ACTIONS[key.to_s]
    end

    def channels_for(key)
      entry = mail_action(key)
      return [] unless entry
      return %w[email letter] if entry.routing == :preference
      return [entry.routing.to_s] if %i[sms fax letter].include?(entry.routing)

      ['email']
    end

    def letter_action_for(template_name)
      MAIL_ACTIONS.values.find { |entry| entry.routing == :preference && entry.template == template_name }&.key
    end

    def notification_action(action)
      NOTIFICATION_ACTIONS[action.to_s]
    end

    def category_for(key, params: {})
      entry = mail_action(key)
      return if entry.nil?
      return entry.category unless entry.category == 'from_test_template'

      template_name = params[:template_name] || params['template_name']
      template_entry = MAIL_ACTIONS.values.find { |candidate| candidate.template.present? && candidate.template == template_name }
      template_entry&.category
    end

    # Template name => category, for grouping templates in the admin controls.
    def template_categories
      MAIL_ACTIONS.values.each_with_object({}) do |entry, categories|
        categories[entry.template] ||= entry.category if entry.template.present?
      end
    end

    # Compatibility views for NotificationService and the template audit.
    def mailer_map
      NOTIFICATION_ACTIONS.values.reject(&:audit_only?).to_h do |entry|
        mailer, method = entry.mail_action.split('#')
        [entry.action, [mailer.constantize, method.to_sym]]
      end
    end

    def audit_only_actions
      NOTIFICATION_ACTIONS.values.select(&:audit_only?).map(&:action)
    end

    def notification_actions_with_routing(routing)
      NOTIFICATION_ACTIONS.values.select { |entry| entry.routing == routing }.map(&:action)
    end

    def notification_actions_owned_by(owner)
      NOTIFICATION_ACTIONS.values.select { |entry| entry.owner == owner }.map(&:action)
    end

    def notification_template_aliases
      NOTIFICATION_ACTIONS.values.each_with_object({}) do |entry, aliases|
        template = entry.mail_action && mail_action(entry.mail_action)&.template
        aliases[entry.action] = template if template
      end
    end
  end
end
