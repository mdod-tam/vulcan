# frozen_string_literal: true

module Vendors
  # Converts existing tax values without changing profile timestamps, W9 status, or audit history.
  class TaxRecordBackfill
    def self.call(after_user_id: 0, after_event_id: 0, batch_size: 100, &progress)
      raise ArgumentError, 'batch_size must be positive' unless batch_size.positive?

      new(after_user_id, after_event_id, batch_size, progress).call
    end

    def initialize(after_user_id, after_event_id, batch_size, progress)
      @after_user_id = after_user_id
      @after_event_id = after_event_id
      @batch_size = batch_size
      @progress = progress
    end

    def call
      encrypt_users
      encrypt_audit_copies
      cursors
    end

    private

    def encrypt_users
      User.where.not(business_tax_id: nil).find_in_batches(start: @after_user_id + 1, batch_size: @batch_size) do |users|
        users.each do |user|
          user.with_lock do
            next if user.business_tax_id.blank? || user.encrypted_attribute?(:business_tax_id)

            # Storage repair bypasses validations/callbacks to preserve certified details and history.
            user.update_columns(business_tax_id: user.business_tax_id) # rubocop:disable Rails/SkipsModelValidations
          end
        end
        @after_user_id = users.last.id
        @progress&.call(cursors)
      end
    end

    def encrypt_audit_copies
      Event.where("metadata -> 'changes' ? 'business_tax_id'")
           .find_in_batches(start: @after_event_id + 1, batch_size: @batch_size) do |events|
        events.each { |event| encrypt_audit_copy(event) }
        @after_event_id = events.last.id
        @progress&.call(cursors)
      end
    end

    def encrypt_audit_copy(event)
      event.with_lock do
        changes = event.metadata['changes']
        tax_change = changes['business_tax_id']
        next if tax_change.blank?

        values = event.change_values.present? ? JSON.parse(event.change_values) : {}
        values['business_tax_id'] = tax_change
        metadata = event.metadata.merge('changes' => changes.merge('business_tax_id' => {}))
        # Move only the historical values; do not recreate events or change their timestamps.
        event.update_columns(metadata: metadata, change_values: values.to_json) # rubocop:disable Rails/SkipsModelValidations
      end
    rescue JSON::ParserError
      raise ArgumentError, "Event #{event.id} contains invalid encrypted audit data"
    end

    def cursors
      { after_user_id: @after_user_id, after_event_id: @after_event_id }
    end
  end
end
