# frozen_string_literal: true

module ApplicationHelper
  include ConstituentPortal::ActivityHelper
  include ActiveStorageHelper
  include ProofUploadFormatsHelper
  include Pagy::Frontend
  include BadgeHelper
  include DateInputHelper
  include ConstituentCommunicationLabelsHelper

  def application_status_badge(application)
    status_badge(:application, application.status)
  end

  def fulfillment_type_badge(application)
    badge(application.voucher_fulfillment? ? 'Fulfillment: Voucher' : 'Fulfillment: Equipment Order', :neutral, size: :lg)
  end

  def proof_status_badge(_proof_type, status)
    status_badge(:proof, status)
  end

  def evaluation_status_badge(evaluation)
    status_badge(:evaluation, evaluation.status)
  end

  def training_session_status_badge(session, label: nil)
    status_badge(:training_session, session.status, label: label)
  end

  def training_duration_hours_label(duration_hours)
    hours = number_with_precision(duration_hours, precision: 2, strip_insignificant_zeros: true)

    t('trainer_workflow.duration_label', count: duration_hours.to_f, hours: hours)
  end

  def disability_certification_status_badge(application)
    status_badge(:certification, application.disability_certification_status, label: application.disability_certification_status.titleize)
  end

  def document_signing_status_badge(application)
    return nil if application.document_signing_status.blank?
    return nil if application.document_signing_status == 'not_sent'

    status = application.document_signing_status
    label = case status.to_s
            when 'sent' then 'Sent for Signing'
            when 'opened' then 'Opened by Provider'
            when 'signed' then 'Signed by Provider'
            when 'declined' then 'Declined by Provider'
            else status.to_s.humanize
            end

    status_badge(:document_signing, status, label: label, size: nil)
  end

  def admin_fulfillment_badge(application)
    labels = { voucher_no_equipment: 'Voucher - No Equipment Order',
               needs_action: 'Needs Ordering', po_sent: 'Ordered', shipped: 'Shipped', no_equipment: 'No equipment needed',
               needs_catalog_product: 'Needs a catalog product', outside_catalog: 'Outside-catalog recommendation' }
    state = application.admin_fulfillment_responsibility_state
    label = labels[state]
    return unless label

    badge(safe_join([tag.span('Fulfillment Status: ', class: 'sr-only'), label]), badge_variant_for(:equipment, state))
  end

  def proof_review_button_text(application, proof_type)
    case application.proof_review_state(proof_type)
    when :resubmitted then 'Review Resubmitted Proof'
    when :rejected then 'Review Rejected Proof'
    else 'Review Proof'
    end
  end

  def proof_review_button_class(application, proof_type)
    application.proof_review_state(proof_type) == :rejected ? 'btn-danger' : 'btn-primary'
  end

  # Alias of the generated constituent_portal_application_new_proof_path. Views and tests use this name.
  def new_proof_constituent_portal_application_path(application, **)
    constituent_portal_application_new_proof_path(application, **)
  end

  # check_box_tag has no form binding or hidden field, so an unchecked box is an absent key.
  # A submitted value wins. Otherwise the stored value decides.
  def disability_information_release_authorized_checked?(application)
    submitted = params.dig(:application, :disability_information_release_authorized)
    return ActiveModel::Type::Boolean.new.cast(submitted) if submitted.present?

    application.present? && application.disability_information_release_authorized.present?
  end

  # Submitted values are raw strings, so cast them instead of comparing with "1".
  # A submitted false is a real answer. Rails sends a hidden "0" for an unchecked box, so only an
  # absent key falls back to the stored selection. Otherwise a failed submit reverts the edit.
  def disability_checked?(field, applicant)
    submitted = params.dig(:application, field)
    return ActiveModel::Type::Boolean.new.cast(submitted) unless submitted.nil?

    applicant.present? && applicant.public_send(field).present?
  end
end
