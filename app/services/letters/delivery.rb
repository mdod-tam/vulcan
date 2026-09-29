# frozen_string_literal: true

require 'zip'

module Letters
  # Both renderers admit through this owner; controllers and merge handling use its transitions.
  class Delivery
    class ReleaseDenied < StandardError
      attr_reader :reasons

      def initialize(reasons)
        @reasons = reasons
        super(reasons.map { |id, reason| "Letter ##{id}: #{reason}" }.join(' '))
      end
    end

    Export = Data.define(:bytes, :filename, :content_type)

    def self.queue!(recipient:, application:, letter_type:, context:, actor: nil, secure_request_form: nil, request_key: nil) # rubocop:disable Metrics/ParameterLists
      action = context&.dig('mail_action')
      EmailDelivery.verify!(action, context: context, channel: 'letter')
      key = [action, application&.id, recipient.id, request_key || context.fetch('request_id')].join(':')
      existing = PrintQueueItem.find_by(delivery_key: key)
      return retry_item!(existing) if existing

      recipient.reload
      application&.reload
      identity = PrintQueueItem.identity_for(recipient: recipient, application: application, secure_request_form: secure_request_form)
      pdf = yield
      raise 'Letter renderer did not produce a PDF' unless pdf

      blob = ActiveStorage::Blob.create_and_upload!(io: pdf, filename: 'letter.pdf', content_type: 'application/pdf')
      item = PrintQueueItem.new(constituent: recipient, application: application, letter_type: letter_type, admin: actor,
                                delivery_key: key, delivery_context: context, delivery_identity: identity,
                                secure_request_form: secure_request_form)
      admit!(item, blob)
    rescue ActiveRecord::RecordNotUnique
      retry_item!(PrintQueueItem.find_by!(delivery_key: key))
    rescue ApplicationMailer::DeliverySkipped, EmailDelivery::ConfigurationError => e
      decision = e.is_a?(EmailDelivery::ConfigurationError) ? EmailDelivery::Decision.configuration_error(e.reason) : EmailDelivery::Decision.suppressed(e.reason)
      EmailDelivery::Outcome.record_not_sent(decision, context: context&.merge('channel' => 'letter'), mail_action: action)
      raise
    ensure
      clean_render_artifacts(pdf, blob)
    end

    def self.clean_render_artifacts(pdf, blob)
      pdf&.close
      pdf&.unlink if pdf.respond_to?(:unlink)
      blob&.purge if blob&.persisted? && !ActiveStorage::Attachment.exists?(blob_id: blob.id)
    end
    private_class_method :clean_render_artifacts

    def self.admit!(item, blob)
      context = item.delivery_context
      EmailDelivery::Policy.with_locked_controls([context], channel: :letter) do
        User.where(id: item.constituent_id).lock.load
        item.application&.lock!
        item.secure_request_form&.lock!
        item.constituent.reload
        identity = PrintQueueItem.identity_for(recipient: item.constituent, application: item.application, secure_request_form: item.secure_request_form)
        raise ApplicationMailer::DeliverySkipped.new(reason: 'delivery_identity_changed') unless identity == item.delivery_identity

        EmailDelivery.verify!(context['mail_action'], context: context, channel: :letter)
        item.pdf_letter.attach(blob)
        item.save!
        Notification.find_by(id: context['notification_id'])&.record_delivery_handoff!(channel: :letter, state: :queued)
      end
      item
    end
    private_class_method :admit!

    def self.export!(ids, actor:)
      items = load_items!(ids)
      refusals = decisions_for(items)
      reject!(items, refusals, actor: actor) if refusals.any?

      # Fetch and construct the complete artifact before marking any item released.
      blob_ids = items.to_h { |item| [item.id, item.pdf_letter.blob_id] }
      export = build_export(items)
      with_locked_items(items, controls: true) do |locked|
        refusals = decisions_for(locked)
        locked.each do |item|
          refusals[item.id] = EmailDelivery::Decision.suppressed(:artifact_changed) if item.pdf_letter.blob_id != blob_ids[item.id]
        end
        locked.each { |item| item.release_for_printing!(actor: actor) } if refusals.empty?
      end
      reject!(items, refusals, actor: actor) if refusals.any?
      export
    end

    def self.mark_printed!(ids, actor:)
      items = load_items!(ids)
      with_locked_items(items) do |locked|
        locked.each { |item| item.confirm_printed!(actor: actor) }
      end
    end

    def self.cancel!(item, reason:, actor: nil)
      with_locked_items([item]) { |locked| locked.first.cancel_unreleased!(reason: reason, actor: actor) }
      record_refusal(item, EmailDelivery::Decision.suppressed(reason)) if item.reload.canceled?
    end

    # Merge owns the user/application locks already. Cancellation preserves the artifact's old owner.
    def self.cancel_for_recipient_change!(recipient_id:, actor:)
      items = PrintQueueItem.unreleased.where(constituent_id: recipient_id).order(:id).to_a
      with_locked_items(items) do |locked|
        locked.count do |item|
          canceled = item.cancel_unreleased!(reason: 'delivery_identity_changed', actor: actor)
          record_refusal(item, EmailDelivery::Decision.suppressed(:delivery_identity_changed)) if canceled
          canceled
        end
      end
    end

    def self.reconcile_pending!(scope: PrintQueueItem.unreleased)
      scope.find_each do |item|
        decision = item.delivery_decision
        cancel!(item, reason: decision.reason) if decision.suppressed?
      end
    end

    def self.load_items!(ids)
      selected = Array(ids).map(&:to_s).uniq
      raise ReleaseDenied, { 'selection' => 'Select at least one letter.' } if selected.empty?

      items = PrintQueueItem.where(id: selected).order(:id).includes(:constituent, :application, :secure_request_form, pdf_letter_attachment: :blob).to_a
      raise ReleaseDenied, { 'selection' => 'One or more selected letters no longer exist.' } unless items.map { |item| item.id.to_s }.sort == selected.sort

      items
    end
    private_class_method :load_items!

    def self.with_locked_items(items, controls: false, &block)
      operation = lambda do
        PrintQueueItem.transaction do
          User.where(id: items.map(&:constituent_id)).order(:id).lock.load
          Application.where(id: items.map(&:application_id)).order(:id).lock.load
          SecureRequestForm.where(id: items.map(&:secure_request_form_id)).order(:id).lock.load
          locked = PrintQueueItem.where(id: items.map(&:id)).order(:id).lock.to_a
          block.call(locked)
        end
      end
      if controls
        EmailDelivery::Policy.with_locked_controls(items.map(&:delivery_context), channel: :letter, &operation)
      else
        operation.call
      end
    end
    private_class_method :with_locked_items

    def self.decisions_for(items)
      items.each_with_object({}) do |item, refusals|
        decision = item.delivery_decision
        refusals[item.id] = decision unless decision.allowed?
      end
    end
    private_class_method :decisions_for

    def self.reject!(items, refusals, actor:)
      items.each do |item|
        next unless (decision = refusals[item.id])

        cancel!(item, reason: decision.reason, actor: actor) if decision.suppressed? && item.released_at.nil?
        record_refusal(item, decision) unless item.canceled?
      end
      raise(ReleaseDenied, refusals.transform_values { |decision| EmailDelivery::ControlPanel.reason_text(decision.reason) })
    end
    private_class_method :reject!

    def self.record_refusal(item, decision)
      # A refused re-download is a new attempt; it must not erase the original notification history.
      context = item.delivery_context&.merge('channel' => 'letter')
      context = context&.except('notification_id')&.merge('request_id' => SecureRandom.uuid) if item.released_at
      EmailDelivery::Outcome.record_not_sent(decision, context: context, mail_action: context&.dig('mail_action'))
    end
    private_class_method :record_refusal

    def self.retry_item!(item)
      decision = item.delivery_decision
      return item if decision.allowed?

      record_refusal(item, decision)
      decision.raise_if_configuration_error!
      raise ApplicationMailer::DeliverySkipped.new(reason: decision.reason)
    end
    private_class_method :retry_item!

    def self.build_export(items)
      missing = items.reject { |item| item.pdf_letter.attached? }
      raise(ReleaseDenied, missing.to_h { |item| [item.id, 'The PDF is missing. Issue a new letter.'] }) if missing.any?

      return Export.new(bytes: items.first.pdf_letter.download, filename: items.first.pdf_filename, content_type: 'application/pdf') if items.one?

      bytes = Zip::OutputStream.write_buffer do |zip|
        items.each do |item|
          zip.put_next_entry(item.pdf_filename)
          zip.write(item.pdf_letter.download)
        end
      end.string
      Export.new(bytes: bytes, filename: "letters_#{Time.current.to_date.iso8601}.zip", content_type: 'application/zip')
    end
    private_class_method :build_export
  end
end
