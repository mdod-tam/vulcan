# frozen_string_literal: true

module Icanconnect
  class IncomeFollowUp
    STAGE = 'icanconnect_income_follow_up'

    def self.requests_by_application(application_ids)
      candidates = Application.approved_deafblind.fulfillment_type_voucher.where(id: application_ids)
                              .where.not(id: Application.awaiting_income_proof_review.select(:id))
                              .where.not(id: Application.income_proof_status_approved.where.associated(:income_proof_attachment).select(:id))
      requests = candidates.ids.index_with(nil)
      requests.merge(active_request_dates(requests.keys))
    end

    def self.active_request_dates(application_ids)
      requests = SecureRequestForm.income_proof.active.where(application_id: application_ids)
      delivered_forms = Notification.with_delivery_handoff
                                    .where(action: 'proof_resubmission_requested', notifiable_type: 'Application', notifiable_id: application_ids)
                                    .select(Arel.sql("notifications.metadata->>'secure_request_form_id'"))
      requests.where('CAST(secure_request_forms.id AS text) IN (?)', delivered_forms).group(:application_id).maximum(:sent_at)
    end
    private_class_method :active_request_dates
  end
end
