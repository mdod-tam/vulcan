# frozen_string_literal: true

module ApplicationProviderInfoRequests
  extend ActiveSupport::Concern

  included do
    has_many :secure_request_forms, dependent: :destroy

    scope :with_provider_info_prerequisites_met, lambda {
      where(residency_proof_status: residency_proof_statuses[:approved],
            id_proof_status: id_proof_statuses[:approved])
        .where(
          arel_table[:income_proof_required].eq(false)
            .or(arel_table[:income_proof_status].eq(income_proof_statuses[:approved]))
        )
    }

    scope :missing_required_provider_info, lambda {
      quoted_table = connection.quote_table_name(table_name)

      where(
        "#{quoted_table}.medical_provider_name IS NULL OR #{quoted_table}.medical_provider_name = '' OR " \
        "#{quoted_table}.medical_provider_phone IS NULL OR #{quoted_table}.medical_provider_phone = '' OR " \
        "#{quoted_table}.medical_provider_email IS NULL OR #{quoted_table}.medical_provider_email = ''"
      )
    }

    scope :pending_provider_info, -> { with_provider_info_prerequisites_met.missing_required_provider_info }
  end
end
