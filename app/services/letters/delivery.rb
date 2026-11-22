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

    def self.queue!(recipient:, application:, letter_type:, context:, actor: nil, secure_request_form: nil, request_key: nil, finalize_request: nil) # rubocop:disable Metrics/ParameterLists
      action = context&.dig('mail_action')
      EmailDelivery.verify!(action, context: context, channel: 'letter')
      # A replacement gets a new request ID at admission. This key keeps the preview ID.
      # Checking the original request under lock prevents duplicate replacements.
      key = [action, application&.id, recipient.id, request_key || context.fetch('request_id')].join(':')
      existing = PrintQueueItem.find_by(delivery_key: key)
      return retry_item!(existing) if existing

      recipient.reload
      application&.reload
      verify_mailing_address!(recipient, action)
      identity = PrintQueueItem.identity_for(recipient: recipient, application: application, secure_request_form: secure_request_form)
      pdf = yield
      raise 'Letter renderer did not produce a PDF' unless pdf

      blob = ActiveStorage::Blob.create_and_upload!(io: pdf, filename: 'letter.pdf', content_type: 'application/pdf')
      item = PrintQueueItem.new(constituent: recipient, application: application, letter_type: letter_type, admin: actor,
                                delivery_key: key, delivery_context: context, delivery_identity: identity,
                                secure_request_form: secure_request_form)
      admit!(item, blob, finalize_request: finalize_request)
    rescue ActiveRecord::RecordNotUnique
      retry_item!(PrintQueueItem.find_by!(delivery_key: key))
    rescue ApplicationMailer::DeliverySkipped, EmailDelivery::ConfigurationError => e
      decision = e.is_a?(EmailDelivery::ConfigurationError) ? e.decision : EmailDelivery::Decision.suppressed(e.reason)
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

    def self.verify_mailing_address!(recipient, action)
      return unless EmailDelivery::Catalog.mail_action(action)&.routing == :preference
      return if recipient.complete_mailing_address?

      reason = :incomplete_mailing_address
      raise EmailDelivery::ConfigurationError.new(EmailDelivery::ControlPanel.reason_text(reason), reason: reason)
    end
    private_class_method :verify_mailing_address!

    def self.admit!(item, blob, finalize_request: nil)
      context = item.delivery_context
      EmailDelivery::Policy.with_locked_controls([context], channel: :letter, requires_new: finalize_request.present?) do
        # The callback issues the successor and retires the previous request in this transaction.
        finalize_request&.call(item)
        User.where(id: [item.constituent_id, item.secure_request_form&.recipient_id]).order(:id).lock.load
        item.application&.lock!
        lock_recipient_relationships([item.application]) if item.secure_request_form
        item.secure_request_form&.lock!
        item.constituent.reload
        verify_mailing_address!(item.constituent, context['mail_action'])
        raise ApplicationMailer::DeliverySkipped.new(reason: 'request_no_longer_active') if item.secure_request_form && !item.secure_request_form.postal_request_open?

        identity = PrintQueueItem.identity_for(recipient: item.constituent, application: item.application, secure_request_form: item.secure_request_form)
        raise ApplicationMailer::DeliverySkipped.new(reason: 'delivery_identity_changed') unless identity == item.delivery_identity
        if item.secure_request_form && !item.secure_request_form.postal_recipient_authorized?(application: item.application, address_owner_id: item.constituent_id)
          raise ApplicationMailer::DeliverySkipped.new(reason: 'letter_recipient_ineligible')
        end

        EmailDelivery.verify!(context['mail_action'], context: context, channel: :letter)
        item.pdf_letter.attach(blob)
        item.save!
        Notification.find_by(id: item.delivery_context['notification_id'])&.record_delivery_handoff!(channel: :letter, state: :queued)
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

    def self.cancel!(item, reason:, actor: nil, unreleased_only: false)
      with_locked_items([item]) do |locked|
        current = locked.first
        next false if unreleased_only && current.released_at?

        cancel_locked!(current, reason: reason, actor: actor)
      end
    end

    # Issuance holds the application, prior forms, and all pending letter recipients.
    def self.cancel_replaced_requests!(request_ids, actor:)
      cancel_request_letters!(PrintQueueItem.pending, request_ids, actor: actor)
    end

    # The response/revocation writer has already locked and closed these forms.
    def self.cancel_closed_requests!(request_ids, actor:)
      cancel_request_letters!(PrintQueueItem.unreleased, request_ids, actor: actor)
    end

    def self.cancel_request_letters!(scope, request_ids, actor:)
      scope.where(secure_request_form_id: request_ids).order(:id).lock.each do |item|
        cancel_locked!(item, reason: 'request_no_longer_active', actor: actor)
      end
    end
    private_class_method :cancel_request_letters!

    # Merge owns the user/application locks already. Cancellation preserves the artifact's old owner.
    def self.cancel_for_recipient_change!(recipient_id:, actor:)
      items = PrintQueueItem.unreleased.where(constituent_id: recipient_id).order(:id).to_a
      with_locked_items(items) do |locked|
        locked.count { |item| !item.released_at? && cancel_locked!(item, reason: 'delivery_identity_changed', actor: actor) }
      end
    end

    def self.reconcile_pending!(scope: PrintQueueItem.unreleased)
      scope.find_each do |item|
        with_locked_items([item], controls: true) do |locked|
          current = locked.first
          next unless current&.pending? && current.released_at.nil?

          decision = current.delivery_decision
          cancel_locked!(current, reason: decision.reason, actor: nil) if decision.suppressed?
        end
      end
    end

    def self.cancel_locked!(item, reason:, actor:)
      return false unless item.cancel_pending!(reason: reason, actor: actor)

      record_refusal(item, EmailDelivery::Decision.suppressed(reason)) unless item.released_at?
      true
    end
    private_class_method :cancel_locked!

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
          requests = SecureRequestForm.where(id: items.map(&:secure_request_form_id)).order(:id)
          User.where(id: items.map(&:constituent_id) + requests.pluck(:recipient_id)).order(:id).lock.load
          applications = Application.where(id: items.map(&:application_id)).order(:id).lock.to_a
          lock_recipient_relationships(applications) if items.any?(&:secure_request_form_id?)
          requests.lock.load
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

    def self.lock_recipient_relationships(applications)
      GuardianRelationship.where(dependent_id: applications.compact.map(&:user_id)).order(:id).lock.load
    end
    private_class_method :lock_recipient_relationships

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

        canceled_now = decision.suppressed? && item.released_at.nil? &&
                       cancel!(item, reason: decision.reason, actor: actor, unreleased_only: true)
        item.reload
        record_refusal(item, decision) if !canceled_now && (!item.canceled? || item.released_at?)
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
