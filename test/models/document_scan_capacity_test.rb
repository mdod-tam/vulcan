# frozen_string_literal: true

require 'test_helper'

class DocumentScanCapacityTest < ActiveSupport::TestCase
  setup { @user = create(:constituent) }

  test 'public pending uploads leave capacity for staff and secure forms' do
    10.times { existing_scan(user: @user) }

    assert_raises(DocumentScan::LimitExceeded) { stage(user: create(:constituent)) }
    assert stage(user: create(:admin)).pending?
    assert stage(secure_form: create(:secure_request_form)).pending?
    assert stage(continuation: 'docuseal').pending?
  end

  test 'the public daily allocation cannot consume the reserved staff capacity' do
    50.times { existing_scan(user: @user, status: 'clean') }

    assert_raises(DocumentScan::LimitExceeded) { stage(user: create(:constituent)) }
    DocumentScan.where(user: @user).find_each(&:dismiss!)
    assert_raises(DocumentScan::LimitExceeded) { stage(user: create(:constituent)) }
    @user.destroy!
    assert_raises(DocumentScan::LimitExceeded) { stage(user: create(:constituent)) }
    assert stage(user: create(:admin)).pending?
    assert stage(secure_form: create(:secure_request_form)).pending?
    assert stage(continuation: 'docuseal').pending?
  end

  test 'each admin can allocate sixty files per rolling day without using the public account cap' do
    admin = create(:admin)
    59.times { existing_scan(user: admin, status: 'clean') }

    assert stage(user: admin).pending?
    assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count'] do
      assert_raises(DocumentScan::LimitExceeded) { stage(user: admin) }
    end
    assert stage(user: create(:admin)).pending?
  end

  test 'an admin allocation older than a rolling day no longer consumes the admin limit' do
    admin = create(:admin)
    60.times { existing_scan(user: admin, status: 'clean') }
    DocumentScan.where(user: admin).first!.update!(created_at: 1.day.ago - 1.second)

    assert stage(user: admin).pending?
    assert_raises(DocumentScan::LimitExceeded) { stage(user: admin) }
  end

  test 'trusted intake still stops at the hard daily and pending program caps' do
    admin = create(:admin)
    existing_scan(user: admin)
    stub_const(DocumentScans::Stager, :GLOBAL_DAILY_LIMIT, 1) do
      assert_raises(DocumentScan::LimitExceeded) { stage(user: admin) }
    end
    stub_const(DocumentScans::Stager, :MAX_PENDING, 1) do
      assert_raises(DocumentScan::LimitExceeded) { stage(user: admin) }
    end
  end

  private

  def stage(**owner)
    input = Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')
    DocumentScan.stage!(input: input, purpose: :proof, slot: 'income_proof', **owner)
  end

  def existing_scan(**attributes)
    blob = ActiveStorage::Blob.create_before_direct_upload!(filename: 'proof.pdf', byte_size: 100, checksum: 'synthetic', content_type: 'application/pdf')
    DocumentScan.create!(blob: blob, purpose: :proof, slot: 'income_proof', sha256: 'a' * 64,
                         next_attempt_at: Time.current, **attributes)
  end
end
