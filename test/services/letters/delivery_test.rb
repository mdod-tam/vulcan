# frozen_string_literal: true

require 'test_helper'

module Letters
  class DeliveryTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      ensure_system_audit_actor!
      @recipient = create(:constituent)
      @application = create(:application, user: @recipient)
      @action = 'Letters#medical_certification_form'
      @context = EmailDelivery::Policy.capture(mail_action: @action)
    end

    test 'retry admits one persisted item and attachment' do
      first = queue
      assert_no_difference ['PrintQueueItem.count', 'ActiveStorage::Blob.count'] do
        second = queue { flunk 'A completed retry must not render again' }
        assert_equal first.id, second.id
      end
      assert first.pdf_letter.attached?
    end

    test 'letter channel refusal happens before rendering or admission' do
      toggle(EmailDelivery::CHANNEL_CONTROLS['letter'], false)
      assert_no_difference 'PrintQueueItem.count' do
        assert_raises(ApplicationMailer::DeliverySkipped) { queue { flunk 'Denied letter rendered' } }
      end
    end

    test 'a disable during rendering leaves no queue item or uploaded blob' do
      assert_no_difference ['PrintQueueItem.count', 'ActiveStorage::Blob.count'] do
        assert_raises(ApplicationMailer::DeliverySkipped) do
          queue do
            toggle(EmailDelivery::ALL_CONTROL, false)
            StringIO.new('%PDF prepared')
          end
        end
      end
    end

    test 'a rendering failure does not consume the durable request key' do
      assert_no_difference 'PrintQueueItem.count' do
        assert_raises(RuntimeError) { queue { raise 'render failed' } }
      end
      assert queue.persisted?
    end

    test 'export records release separately from physical print confirmation' do
      item = queue
      export = Delivery.export!([item.id], actor: @admin)
      assert_equal '%PDF prepared', export.bytes
      assert item.reload.released_at
      assert item.pending?
      assert_nil item.printed_at

      Delivery.mark_printed!([item.id], actor: @admin)
      assert item.reload.printed?
      assert item.printed_at
    end

    test 'mark printed cannot skip release' do
      item = queue
      assert_raises(Delivery::ReleaseDenied) { Delivery.mark_printed!([item.id], actor: @admin) }
      assert item.reload.pending?
      assert_nil item.printed_at
    end

    test 'off on before release permanently cancels the item' do
      item = queue
      toggle(EmailDelivery::ALL_CONTROL, false)
      toggle(EmailDelivery::ALL_CONTROL, true)

      assert_raises(Delivery::ReleaseDenied) { Delivery.export!([item.id], actor: @admin) }
      assert item.reload.canceled?
      assert_nil item.released_at
      assert_raises(ApplicationMailer::DeliverySkipped) { queue }
    end

    test 'a changed address cannot release an old PDF' do
      item = queue
      @recipient.update!(physical_address_1: '200 Changed Street')

      assert_raises(Delivery::ReleaseDenied) { Delivery.export!([item.id], actor: @admin) }
      assert item.reload.canceled?
      assert_equal 'delivery_identity_changed', item.cancellation_reason
    end

    test 'a refused re-download preserves released and printed history' do
      item = queue
      Delivery.export!([item.id], actor: @admin)
      released_at = item.reload.released_at
      toggle(EmailDelivery::ALL_CONTROL, false)

      assert_raises(Delivery::ReleaseDenied) { Delivery.export!([item.id], actor: @admin) }
      assert_equal released_at, item.reload.released_at
      assert item.pending?
      Delivery.mark_printed!([item.id], actor: @admin)
      assert item.reload.printed?
    end

    test 'a batch with a canceled item releases none of its valid siblings' do
      first = queue
      second = queue(request_key: 'second')
      Delivery.cancel!(second, reason: 'operator_canceled', actor: @admin)

      assert_raises(Delivery::ReleaseDenied) { Delivery.export!([first.id, second.id], actor: @admin) }
      assert_nil first.reload.released_at
      assert_nil second.reload.released_at
    end

    test 'archive names distinguish repeated notices for the same recipient and type' do
      items = [queue, queue(request_key: 'second')]
      export = Delivery.export!(items.map(&:id), actor: @admin)
      names = []
      Zip::InputStream.open(StringIO.new(export.bytes)) do |zip|
        while (entry = zip.get_next_entry)
          names << entry.name
        end
      end
      assert_equal items.map(&:pdf_filename).sort, names.sort
      assert_equal 2, names.uniq.size
    end

    test 'a storage failure does not mark any batch item released' do
      items = [queue, queue(request_key: 'second')]
      items.last.pdf_letter.blob.service.delete(items.last.pdf_letter.blob.key)

      assert_raises(ActiveStorage::FileNotFoundError) { Delivery.export!(items.map(&:id), actor: @admin) }
      assert(PrintQueueItem.where(id: items.map(&:id)).all? { |item| item.released_at.nil? })
    end

    private

    def queue(request_key: nil, &render)
      Delivery.queue!(recipient: @recipient, application: @application, letter_type: :medical_certification_form,
                      context: @context, actor: @admin, request_key: request_key, &render || -> { StringIO.new('%PDF prepared') })
    end

    def toggle(name, enabled)
      EmailDelivery::ControlWriter.set(name: name, enabled: enabled, actor: @admin, operation_id: SecureRandom.uuid)
    end
  end
end
