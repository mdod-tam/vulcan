# frozen_string_literal: true

module EmailDelivery
  # Batch the records needed by the shared component; rendering performs no provider requests.
  module Visibility
    def self.preload(records)
      records = records.to_a
      return records if records.empty?

      ActiveRecord::Associations::Preloader.new(records: records, associations: { email_delivery_attempts: :delivery_owner }).call
      Capture::REQUEST_KEYS.each do |key, klass|
        forms = records.grep(klass)
        next if forms.empty?

        notices = Notification.where('metadata ->> ? IN (?)', key, forms.map { |form| form.id.to_s }).order(:id).to_a
        by_form = notices.index_by { |notice| notice.metadata[key].to_i }
        forms.each { |form| form.delivery_notification = by_form[form.id] }
      end
      letters = records.select { |record| record.respond_to?(:print_queue_items) }
      ActiveRecord::Associations::Preloader.new(records: letters, associations: :print_queue_items).call if letters.any?
      preload_letter_states(letters.flat_map(&:print_queue_items))
      records
    end

    def self.preload_letter_states(items)
      return if items.empty?

      ActiveRecord::Associations::Preloader.new(records: items, associations: %i[constituent application secure_request_form]).call
      active_ids = SecureRequestForm.active.where(id: items.filter_map(&:secure_request_form_id)).pluck(:id).to_set
      # Shared controls/templates are read once. This cache is display-only; release rechecks under locks.
      PrintQueueItem.cache do
        items.each { |item| item.preloaded_delivery_state = item.display_delivery_state(active_request_ids: active_ids) }
      end
    end

    def self.application_attention(applications)
      ids = applications.map(&:id)
      return {} if ids.empty?

      attempts = attention_scope.where(application_id: ids).order(:id).to_a
      latest_attempts(attempts).select(&:attention?).group_by(&:application_id)
    end

    def self.contact_attention(user)
      return [] if user.email.blank?

      attempts = attention_scope.where(delivery_owner_id: user.id, recipient_key: EmailDeliveryAttempt.recipient_key(user.email)).order(:id).to_a
      latest_attempts(attempts).select(&:attention?).reverse
    end

    def self.attention_scope
      EmailDeliveryAttempt.includes(:origin, :delivery_owner, application: %i[income_proof_attachment residency_proof_attachment id_proof_attachment])
    end

    def self.latest_attempts(attempts)
      attempts.group_by do |attempt|
        recipient = attempt.mail_action.start_with?('MedicalProviderMailer#') ? 'medical_provider' : attempt.recipient_id || attempt.recipient_key
        [attempt.origin_type, attempt.origin_id, attempt.mail_action, recipient]
      end.values.map(&:last)
    end
  end
end
