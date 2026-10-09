# frozen_string_literal: true

require 'test_helper'

class VendorsW9ProtectionBackfillTest < ActiveSupport::TestCase
  setup do
    @starting_vendor_id = Users::Vendor.maximum(:id).to_i
    @starting_blob_id = ActiveStorage::Blob.maximum(:id).to_i
  end

  test 'current, retained, reviewed and derived documents move off copied storage keys without changing review history' do
    vendor = create(:vendor, :with_w9)
    current = vendor.w9_form.blob
    retained = stored_blob('retained.pdf')
    reviewed = stored_blob('reviewed.pdf')
    vendor.w9_archive.attach(retained)
    review = create(:w9_review, vendor: vendor, reviewed_blob: reviewed)
    unknown = create(:w9_review, vendor: vendor, reviewed_blob: current)
    W9Review.where(id: unknown.id).update_all(reviewed_blob_id: nil)
    preview = stored_blob('preview.png', fixture: 'sample.png', content_type: 'image/png')
    variant = stored_blob('variant.png', fixture: 'sample.png', content_type: 'image/png')
    current.preview_image.attach(preview)
    variant_record = ActiveStorage::VariantRecord.create!(blob: current, variation_digest: 'existing-variant')
    variant_record.image.attach(variant)
    blobs = [current, retained, reviewed, preview, variant]
    old_keys = blobs.to_h { |blob| [blob.id, blob.key] }
    original_dates = blobs.to_h { |blob| [blob.id, blob.created_at] }
    legacy_variant_key = "variants/#{current.key}/legacy-image"
    current.service.upload(legacy_variant_key, StringIO.new('old derivative'))

    run_backfill(cutover_at: Time.current, batch_size: 1)

    blobs.each do |blob|
      blob.reload
      assert_equal vendor.id, blob.metadata[Vendors::W9Document::OWNER_KEY]
      assert_not_equal old_keys[blob.id], blob.key
      assert_not blob.service.exist?(old_keys[blob.id])
      assert blob.service.exist?(blob.key)
      assert_equal original_dates[blob.id], blob.created_at
      assert blob.metadata[Vendors::W9ProtectionBackfill::ROTATED_AT].present?
      assert_not blob.metadata.key?(Vendors::W9ProtectionBackfill::OLD_KEY)
    end
    assert_not current.service.exist?(legacy_variant_key)
    assert_equal reviewed.id, review.reload.reviewed_blob_id
    assert_nil unknown.reload.reviewed_blob_id
    assert vendor.w9_archive.blobs.exists?(reviewed.id)
    assert_equal current.id, vendor.reload.w9_form.blob.id

    rotated_keys = blobs.to_h { |blob| [blob.id, blob.key] }
    run_backfill(cutover_at: Time.current, batch_size: 1)
    assert_equal(rotated_keys, blobs.to_h { |blob| [blob.id, blob.reload.key] })
  end

  test 'vendor-bound staged retry references retain their original seven-day expiry while generic legacy uploads are invalidated' do
    vendor = create(:vendor)
    staged = nil
    generic = nil
    travel_to 2.days.ago do
      staged = stored_blob('bound-staged.pdf')
      Vendors::W9Document.protect!(staged, vendor: vendor)
      generic = stored_blob('unattributed-staged.pdf')
    end
    deadline = staged.created_at + CleanupUnattachedUploadsJob::RETENTION
    reference = Vendors::W9Document.reference(staged, vendor: vendor)
    original_key = staged.key
    original_date = staged.created_at
    cutover = Time.current
    later_upload = nil
    travel_to(1.minute.from_now) { later_upload = stored_blob('later-staged.pdf') }

    run_backfill(cutover_at: cutover, batch_size: 1)

    generic_old_key = generic.key
    assert ActiveStorage::Blob.exists?(generic.id)
    assert generic.reload.metadata[Vendors::W9ProtectionBackfill::QUARANTINED]
    assert_not generic.service.exist?(generic_old_key)
    assert generic.service.exist?(generic.key)
    assert_nil UploadedDocument.restorable(generic.signed_id, record: vendor, name: 'w9_form')
    refusal = assert_raises(UploadedDocument::Refused) do
      UploadedDocument.resolve!(generic.signed_id, record: vendor, name: 'w9_form')
    end
    assert_equal :unavailable, refusal.reason
    assert ActiveStorage::Blob.exists?(later_upload.id)
    assert_equal staged.id, Vendors::W9Document.restorable(reference, vendor: vendor)&.id
    assert_equal original_date, staged.reload.created_at
    assert_not staged.service.exist?(original_key)
    travel_to(deadline + 1.second) { assert_nil Vendors::W9Document.resolve_reference(reference, vendor: vendor) }
  end

  test 'old-key deletion failure keeps a durable checkpoint and retry finishes without another rotation' do
    vendor = create(:vendor, :with_w9)
    blob = vendor.w9_form.blob
    old_key = blob.key
    blob.service.stubs(:delete).with(old_key).raises(IOError, 'storage deletion unavailable')

    assert_raises(IOError) { run_backfill(cutover_at: Time.current) }

    blob.reload
    checkpoint_key = blob.key
    assert_not_equal old_key, checkpoint_key
    assert_equal old_key, blob.metadata[Vendors::W9ProtectionBackfill::OLD_KEY]
    assert Vendors::W9Document.protected_key?(old_key)
    assert blob.service.exist?(old_key)
    assert blob.service.exist?(checkpoint_key)
    blob.service.unstub(:delete)

    run_backfill(cutover_at: Time.current)

    assert_equal checkpoint_key, blob.reload.key
    assert_not blob.service.exist?(old_key)
    assert_not blob.metadata.key?(Vendors::W9ProtectionBackfill::OLD_KEY)
    assert blob.metadata[Vendors::W9ProtectionBackfill::ROTATED_AT].present?
  ensure
    blob&.service&.unstub(:delete)
  end

  test 'cutover progress resumes after completed vendor and staged cursors' do
    first = create(:vendor, :with_w9)
    second = create(:vendor, :with_w9)
    skipped = stored_blob('skipped-staged.pdf')
    removed = stored_blob('removed-staged.pdf')
    progress = []

    options = { cutover_at: Time.current, after_vendor_id: first.id, after_staged_blob_id: skipped.id, batch_size: 1 }
    run_backfill(**options) { |cursors| progress << cursors }

    assert_not first.w9_form.blob.reload.metadata.key?(Vendors::W9ProtectionBackfill::ROTATED_AT)
    assert second.w9_form.blob.reload.metadata.key?(Vendors::W9ProtectionBackfill::ROTATED_AT)
    assert ActiveStorage::Blob.exists?(skipped.id)
    assert ActiveStorage::Blob.exists?(removed.id)
    assert removed.reload.metadata[Vendors::W9ProtectionBackfill::QUARANTINED]
    assert_equal second.id, progress.last[:after_vendor_id]
    assert_equal removed.id, progress.last[:after_staged_blob_id]
  end

  test 'quarantine deletion failure retains its blob and checkpoint until retry and normal cleanup' do
    generic = nil
    travel_to(2.days.ago) { generic = stored_blob('unattributed-staged.pdf') }
    old_key = generic.key
    original_date = generic.created_at
    generic.service.stubs(:delete).with(old_key).raises(IOError, 'storage deletion unavailable')

    assert_raises(IOError) { run_backfill(cutover_at: Time.current) }

    assert ActiveStorage::Blob.exists?(generic.id)
    assert generic.reload.metadata[Vendors::W9ProtectionBackfill::QUARANTINED]
    assert_equal old_key, generic.metadata[Vendors::W9ProtectionBackfill::OLD_KEY]
    assert Vendors::W9Document.protected?(generic)
    assert Vendors::W9Document.protected_key?(old_key)
    checkpoint_key = generic.key
    generic.service.unstub(:delete)

    run_backfill(cutover_at: Time.current)

    assert_equal checkpoint_key, generic.reload.key
    assert_equal original_date, generic.created_at
    assert_not generic.service.exist?(old_key)
    travel_to(original_date + CleanupUnattachedUploadsJob::RETENTION + 1.second) do
      CleanupUnattachedUploadsJob.perform_now
    end
    assert_not ActiveStorage::Blob.exists?(generic.id)
  ensure
    generic&.service&.unstub(:delete)
  end

  test 'cutover instrumentation does not expose old or replacement storage keys' do
    vendor = create(:vendor, :with_w9)
    blob = vendor.w9_form.blob
    old_key = blob.key
    log = StringIO.new
    original_storage_logger = ActiveStorage.logger
    original_record_logger = ActiveRecord::Base.logger
    ActiveStorage.logger = ActiveSupport::Logger.new(log)
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(log)

    run_backfill(cutover_at: Time.current)

    assert_not_includes log.string, old_key
    assert_not_includes log.string, blob.reload.key
  ensure
    ActiveStorage.logger = original_storage_logger
    ActiveRecord::Base.logger = original_record_logger
  end

  private

  def run_backfill(**options, &)
    defaults = { after_vendor_id: @starting_vendor_id, after_staged_blob_id: @starting_blob_id }
    Vendors::W9ProtectionBackfill.call(**defaults.merge(options), &)
  end

  def stored_blob(filename, fixture: 'sample_w9.pdf', content_type: 'application/pdf')
    ActiveStorage::Blob.create_and_upload!(io: file_fixture(fixture).open, filename: filename, content_type: content_type)
  end
end
