# frozen_string_literal: true

module Icanconnect
  class IncomeFollowUp
    STAGE = 'icanconnect_income_follow_up'
    Entry = Data.define(:requested_at, :renewal)

    def self.requests_by_application(application_ids)
      candidates = Application.approved_deafblind.where(id: application_ids)
                              .where.not(id: Application.awaiting_income_proof_review.select(:id))
      verified = Application.income_proof_status_approved.where.associated(:income_proof_attachment)
      initial = candidates.fulfillment_type_voucher.where.not(id: verified.select(:id)).ids
      renewals = IncomeReview.due_application_ids(candidates.select(:id))
      follow_up = initial.index_with(false).merge(renewals.index_with(true))
      requested = active_request_dates(follow_up.keys)

      follow_up.to_h { |id, renewal| [id, Entry.new(requested_at: requested[id], renewal:)] }
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
