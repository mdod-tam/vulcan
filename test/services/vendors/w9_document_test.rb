# frozen_string_literal: true

require 'test_helper'

module Vendors
  class W9DocumentTest < ActiveSupport::TestCase
    test 'ordinary proof attachments do not load their application record while checking W9 protection' do
      application = create(:application, :in_progress)
      application.income_proof.attach(io: file_fixture('sample_w9.pdf').open, filename: 'proof.pdf', content_type: 'application/pdf')
      blob = application.income_proof.blob.reload
      queries = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql] unless payload[:cached] || payload[:name] == 'SCHEMA'
      end

      Application.uncached do
        ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
          assert_not W9Document.protected?(blob)
        end
      end

      assert_empty queries.grep(/FROM "applications"/)
    end

    test 'a known reviewed blob stays protected without an attachment or ownership metadata' do
      vendor = create(:vendor, :with_w9)
      review = create(:w9_review, vendor: vendor)
      blob = review.reviewed_blob
      vendor.w9_form.attachment.delete

      assert_nil blob.metadata[W9Document::OWNER_KEY]
      assert W9Document.protected?(blob.reload)
    end

    test 'preview and tracked variant attachments inherit protection from their W9 parent' do
      vendor = create(:vendor, :with_w9)
      parent = vendor.w9_form.blob
      parent.preview_image.attach(io: file_fixture('sample_w9.pdf').open, filename: 'preview.pdf', content_type: 'application/pdf')
      variant = parent.variant_records.create!(variation_digest: 'synthetic-w9-variation')
      variant.image.attach(io: file_fixture('sample_w9.pdf').open, filename: 'variant.pdf', content_type: 'application/pdf')

      assert W9Document.protected?(parent.preview_image.blob.reload)
      assert W9Document.protected?(variant.image.blob.reload)
    end

    test 'an archived former current reference cannot replace the vendors newer current document' do
      vendor = create(:vendor, :with_w9)
      original = vendor.w9_form.blob
      review_current(vendor)
      reference = W9Document.reference(original, vendor: vendor)
      replacement = ReplaceW9.call(vendor: vendor, file: Rack::Test::UploadedFile.new(file_fixture('sample_w9.pdf'), 'application/pdf'))

      assert_nil W9Document.restorable(reference, vendor: vendor)
      error = assert_raises(UploadedDocument::Refused) do
        vendor.with_lock { W9Document.resolve!(reference, vendor: vendor) }
      end

      assert_equal :attached_elsewhere, error.reason
      assert_equal replacement.id, vendor.reload.w9_form.blob.id
    end

    test 'current archive retry permission does not allow attachments belonging to another vendor' do
      vendor = create(:vendor, :with_w9)
      current = vendor.w9_form.blob
      review_current(vendor)
      other_vendor = create(:vendor)
      other_vendor.w9_archive.attach(current)
      reference = W9Document.reference(current, vendor: vendor)

      error = assert_raises(UploadedDocument::Refused) do
        vendor.with_lock { W9Document.resolve!(reference, vendor: vendor) }
      end

      assert_equal :attached_elsewhere, error.reason
      assert_equal current.id, vendor.reload.w9_form.blob.id
    end

    test 'shared intake still permits only its requested slot unless a domain owner opts in' do
      vendor = create(:vendor, :with_w9)
      current = vendor.w9_form.blob
      review_current(vendor)

      error = assert_raises(UploadedDocument::Refused) do
        vendor.with_lock { UploadedDocument.resolve!(current, record: vendor, name: 'w9_form') }
      end

      assert_equal :attached_elsewhere, error.reason
    end

    private

    def review_current(vendor)
      result = ReviewW9.new(
        vendor: vendor, admin: create(:admin), attributes: { status: 'approved', reviewed_blob_id: vendor.w9_form.blob.id }
      ).call
      assert_predicate result, :success?
    end
  end
end
