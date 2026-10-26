# frozen_string_literal: true

require 'test_helper'

class DocumentScanCapacityTest < ActiveSupport::TestCase
  setup { @user = create(:constituent) }

  test 'one public account can stage its three proof files without taking the entire public pending pool' do
    3.times { existing_scan(user: @user) }

    assert_raises(DocumentScan::LimitExceeded) { stage(user: @user) }
    assert stage(user: create(:constituent)).pending?
    DocumentScan.where(user: @user).first!.dismiss!
    assert stage(user: @user).pending?
  end

  test 'pending staff and secure form uploads have smaller limits than the program pool' do
    admin = create(:admin)
    form = create(:secure_request_form)
    10.times { existing_scan(user: admin) }
    2.times { existing_scan(secure_form: form) }

    assert_raises(DocumentScan::LimitExceeded) { stage(user: admin) }
    assert_raises(DocumentScan::LimitExceeded) { stage(secure_form: form) }
    assert stage(user: create(:admin)).pending?
    assert stage(secure_form: create(:secure_request_form)).pending?
  end

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

  test 'repeated fixture clearances do not consume real upload allocation' do
    4.times do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(file_fixture('income_proof.pdf').binread),
                                                    filename: 'seed-proof.pdf', content_type: 'application/pdf')
      2.times { DocumentScanFixtures.clear!(blob, user: @user) }
    end
    assert_equal 4, DocumentScan.where(user: @user, synthetic_fixture: true).count

    stub_const(DocumentScans::Stager, :GLOBAL_DAILY_LIMIT, 2) do
      first = stage(user: @user)
      second = stage(user: @user)

      assert first.pending?
      assert second.pending?
      assert_not first.synthetic_fixture?
      assert_not second.synthetic_fixture?
      assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count'] do
        assert_raises(DocumentScan::LimitExceeded) { stage(user: @user) }
      end
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
