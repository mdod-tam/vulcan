# frozen_string_literal: true

require 'test_helper'

module Letters
  class DeliveryTest < ActiveSupport::TestCase
    include PdfTextHelper

    setup do
      @admin = create(:admin)
      ensure_system_audit_actor!
      @recipient = create(:constituent)
      @application = create(:application, user: @recipient)
      @action = 'Letters#disability_certification_form'
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

    test 'an ordinary letter override rejects an incomplete postal recipient before admission' do
      @recipient.update!(physical_address_1: nil)
      options = { household_size: 2, annual_income: 100_000, communication_preference: 'letter' }

      assert_no_difference ['PrintQueueItem.count', 'ActiveStorage::Blob.count'] do
        error = assert_raises(EmailDelivery::ConfigurationError) do
          ApplicationNotificationsMailer.income_threshold_exceeded(@recipient, options).deliver_now
        end
        assert_equal 'incomplete_mailing_address', error.reason.to_s
      end

      @recipient.update!(physical_address_1: '123 Main St')
      assert_difference('PrintQueueItem.count', 1) do
        ApplicationNotificationsMailer.income_threshold_exceeded(@recipient, options).deliver_now
      end
    end

    test 'text letters embed fonts for mixed names and refuse unsupported scripts' do
      @recipient.update!(first_name: "Łucja Jose\u0301 Александра 李 さとう 한글", communication_preference: :letter)
      assert_difference('PrintQueueItem.count', 1) do
        ApplicationNotificationsMailer.account_created(@recipient).deliver_now
      end
      bytes = PrintQueueItem.where(constituent: @recipient).sole.pdf_letter.download
      assert bytes.include?('NotoSans-Regular'), 'Expected the embedded Noto Sans font'
      assert bytes.include?('NotoSansCJKJP-Regular'), 'Expected the embedded Noto Sans CJK font'
      assert_no_match(%r{/BaseFont /Helvetica}, bytes)

      @recipient.update!(first_name: 'حسن')
      assert_no_difference('PrintQueueItem.count') do
        error = assert_raises(EmailDelivery::ConfigurationError) { ApplicationNotificationsMailer.account_created(@recipient).deliver_now }
        assert_equal 'unsupported_letter_text', error.reason.to_s
        assert_equal 'U+062D', error.unsupported_codepoint
        assert_no_match(/حسن/, error.message)
      end
      event = Event.where(action: 'email_delivery_configuration_error').order(:id).last
      assert_equal 'U+062D', event.metadata['unsupported_codepoint']
      assert_no_match(/حسن/, event.metadata.to_json)
    end

    test 'a Spanish letter drops invisible paste characters and embeds its Latin font' do
      first_name = "Ma\u200Br\u200Eí\u00ADa"
      @recipient.update!(first_name: first_name, last_name: 'Núñez', locale: :es, communication_preference: :letter)

      assert_difference('PrintQueueItem.count', 1) { ApplicationNotificationsMailer.account_created(@recipient).deliver_now }
      bytes = PrintQueueItem.where(constituent: @recipient).sole.pdf_letter.download

      assert_includes bytes, '/FontFile2'
      assert_no_match(%r{/BaseFont /Helvetica}, bytes)
      assert_includes extracted_pdf_text(bytes), 'María Núñez'
      assert_equal first_name, @recipient.reload.first_name
    end

    test 'other direction controls and unsupported emoji are still refused' do
      { "\u202E" => 'U+202E', '😀' => 'U+1F600' }.each do |character, codepoint|
        error = assert_raises(EmailDelivery::ConfigurationError) { PdfDocument.new.text("abc#{character}def") }
        assert_equal codepoint, error.unsupported_codepoint
        assert_includes error.message, codepoint
        assert_not_includes error.message, character
      end
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

      error = assert_raises(Delivery::ReleaseDenied) { Delivery.export!(items.map(&:id), actor: @admin) }
      assert_equal [items.last.id], error.reasons.keys
      assert(PrintQueueItem.where(id: items.map(&:id)).all? { |item| item.released_at.nil? })
    end

    private

    def queue(request_key: nil, &render)
      Delivery.queue!(recipient: @recipient, application: @application, letter_type: :disability_certification_form,
                      context: @context, actor: @admin, request_key: request_key, &render || -> { StringIO.new('%PDF prepared') })
    end

    def toggle(name, enabled)
      EmailDelivery::ControlWriter.set(name: name, enabled: enabled, actor: @admin, operation_id: SecureRandom.uuid)
    end
  end
end
