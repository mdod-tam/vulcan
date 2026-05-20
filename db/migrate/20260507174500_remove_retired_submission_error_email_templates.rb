# frozen_string_literal: true

class RemoveRetiredSubmissionErrorEmailTemplates < ActiveRecord::Migration[8.0]
  RETIRED_TEMPLATE_NAMES = %w[
    application_notifications_proof_submission_error
    medical_provider_certification_submission_error
  ].freeze

  def up
    EmailTemplate.where(name: RETIRED_TEMPLATE_NAMES).delete_all
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
