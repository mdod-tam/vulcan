# frozen_string_literal: true

class EnforceDeliveryAuditIdentities < ActiveRecord::Migration[8.1]
  def change
    # These outcomes identify a captured request, rather than a five-second deduplication window.
    add_index :events, "action, (metadata->>'request_id')", unique: true,
                                                            name: 'index_events_on_delivery_outcome_request',
                                                            where: <<~SQL.squish
                                                              action IN ('email_delivery_suppressed', 'email_delivery_configuration_error',
                                                                         'email_delivery_enqueue_failed', 'essential_communication_submitted')
                                                              AND NULLIF(BTRIM(metadata->>'request_id'), '') IS NOT NULL
                                                            SQL

    # Cleanup intent and confirmation survive independent queue commits and retry under one identity.
    add_index :events, "action, (metadata->>'operation_id')", unique: true,
                                                              name: 'index_events_on_legacy_mail_removal_operation',
                                                              where: <<~SQL.squish
                                                                action IN ('email_delivery_legacy_job_removal_requested', 'email_delivery_legacy_job_removed')
                                                                AND NULLIF(BTRIM(metadata->>'operation_id'), '') IS NOT NULL
                                                              SQL
  end
end
