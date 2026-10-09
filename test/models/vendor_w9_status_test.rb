# frozen_string_literal: true

require 'test_helper'

class VendorW9StatusTest < ActiveSupport::TestCase
  setup do
    @vendor = create(:vendor, :with_w9)
  end

  test 'a profile edit keeps an approved W9 approved and records nothing' do
    force_w9_status(:approved)

    assert_no_difference -> { Event.where(action: 'w9_details_changed').count } do
      @vendor.update!(phone: '410-555-0199', website_url: 'https://vendor.example.test')
    end
    assert_predicate @vendor.reload, :w9_status_approved?
  end

  test 'an account lockout keeps a rejected W9 rejected' do
    force_w9_status(:rejected)

    @vendor.lock_account!

    assert_predicate @vendor.reload, :w9_status_rejected?
  end

  test 'a newly attached W9 moves an approved W9 to review' do
    force_w9_status(:approved)

    file = Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/sample_w9.pdf'), 'application/pdf')
    Vendors::ReplaceW9.call(vendor: @vendor, file: file)

    assert_predicate @vendor.reload, :w9_status_pending_review?
  end

  test 'a changed tax ID keeps vouchers working and flags the W9 for staff' do
    force_w9_status(:approved)

    @vendor.update!(business_tax_id: '98-7654321', city: 'Annapolis')

    assert_predicate @vendor.reload, :w9_status_approved?
    event = Event.find_by!(action: 'w9_details_changed', auditable: @vendor)
    assert_equal %w[business_tax_id city], event.metadata['changed_fields'].sort
    assert_not_includes event.metadata.to_json, '98-7654321'
  end

  test 'a W9 that already needs replacing is not flagged again' do
    force_w9_status(:rejected)

    assert_no_difference -> { Event.where(action: 'w9_details_changed').count } do
      @vendor.update!(business_tax_id: '98-7654321')
    end
  end

  private

  def force_w9_status(status)
    @vendor.update_column(:w9_status, Users::Vendor.w9_statuses[status])
    @vendor.reload
  end
end
