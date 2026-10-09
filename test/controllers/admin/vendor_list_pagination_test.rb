# frozen_string_literal: true

require 'test_helper'

module Admin
  class VendorListPaginationTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
    end

    test 'vendor pages keep the W9 filter and stable business-name order' do
      # rubocop:disable-next FactoryBot/ExcessiveCreateList -- Exercises more than one 20-row page.
      create_list(:vendor, 23, w9_status: :rejected)
      expected = Users::Vendor.where(w9_status: :rejected).order(:business_name, :id)

      get admin_vendors_path(w9_status: 'rejected')

      assert_response :success
      assert_select 'table tbody tr', count: 20
      assert_select 'nav[aria-label="Vendor pages"] a[rel="next"]' do |links|
        query = Rack::Utils.parse_nested_query(URI.parse(links.first['href']).query)
        assert_equal({ 'w9_status' => 'rejected', 'page' => '2' }, query)
      end

      get admin_vendors_path(w9_status: 'rejected', page: 2)

      assert_response :success
      assert_select 'table tbody tr', count: expected.offset(20).limit(20).count
      expected.offset(20).limit(20).each { |vendor| assert_match vendor.business_name, response.body }
      assert_select 'nav [aria-current="page"]', text: '2'
    end

    test 'review history pages stay scoped to the selected vendor' do
      vendor = create(:vendor)
      reviews = Array.new(23) do |index|
        blob = Rails.root.join('test/fixtures/files/sample_w9.pdf').open do |file|
          ActiveStorage::Blob.create_and_upload!(io: file, filename: "reviewed-w9-#{index}.pdf", content_type: 'application/pdf')
        end
        create(:w9_review, vendor: vendor, admin: @admin, reviewed_blob: blob)
      end
      other_review = create(:w9_review, vendor: create(:vendor, :with_w9), admin: @admin)

      get admin_vendor_w9_reviews_path(vendor)

      assert_response :success
      assert_select 'table tbody tr', count: 20
      assert_select 'nav[aria-label="W9 review pages"] [aria-current="page"]', text: '1'
      assert_select "a[href='#{admin_vendor_w9_review_path(other_review.vendor, other_review)}']", count: 0

      get admin_vendor_w9_reviews_path(vendor, page: 2)

      assert_response :success
      assert_select 'table tbody tr', count: 3
      reviews.sort_by { |review| [review.created_at, review.id] }.first(3).each do |review|
        assert_select "a[href='#{admin_vendor_w9_review_path(vendor, review)}']", text: 'View'
      end
      assert_select 'nav[aria-label="W9 review pages"] [aria-current="page"]', text: '2'
    end
  end
end
