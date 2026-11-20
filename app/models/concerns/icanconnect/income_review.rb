# frozen_string_literal: true

module Icanconnect
  # Reuses ordinary income proof decisions when an approved recipient needs more ICC support.
  module IncomeReview
    extend ActiveSupport::Concern

    included do
      has_many_attached :previous_income_proofs
      validates :previous_income_proofs, document: { purpose: :proof }

      scope :approved_deafblind, lambda {
        certificates = ActiveStorage::Attachment.where(record_type: base_class.name, name: 'disability_certification').select(:record_id)
        status_approved.where(disability_certification_status: :approved, id: certificates,
                              user_id: User.where(hearing_disability: true, vision_disability: true).select(:id))
      }
    end

    def approved_deafblind?
      status_approved? && user.hearing_disability? && user.vision_disability? &&
        disability_certification_status_approved? && disability_certification.attached?
    end

    def income_review_as_of(on)
      proof_reviews.proof_type_income.where(reviewed_at: ..on.to_date.end_of_day).recent.first
    end

    def income_last_verified_at(on: Date.current)
      proof_reviews.proof_type_income.status_approved.where(reviewed_at: ..on.to_date.end_of_day).maximum(:reviewed_at)
    end

    def icanconnect_income_review_due?(on: Date.current)
      date = on.to_date
      return false unless equipment_items.exists?(funding_source: 'icanconnect', delivered_on: ..date)

      verified_at = income_last_verified_at(on: date)
      verified_at.nil? || verified_at.in_time_zone.to_date.next_year <= date
    end

    def income_proof_update_offered?
      income_proof_update_available? && Setting.active?
    end

    def income_proof_update_available?
      return false unless approved_deafblind?
      return !income_proof.attached? if income_proof_status_not_reviewed?

      income_proof_status_rejected? || !income_proof.attached? || icanconnect_income_review_due?
    end
  end
end
