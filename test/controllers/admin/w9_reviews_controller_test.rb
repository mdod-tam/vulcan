# frozen_string_literal: true

require 'test_helper'

module Admin
  class W9ReviewsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_as(@admin)
    end

    test 'should get new with attached w9' do
      vendor = create(:vendor, type: 'Vendor')

      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      vendor.update!(w9_status: :pending_review)
      assert vendor.w9_form.attached?, 'W9 form should be attached'

      get new_admin_vendor_w9_review_path(vendor)

      assert_response :success
      assert_select 'h1', 'Review W9 Form'
    end

    test 'should create approved w9 review' do
      vendor = create(:vendor, type: 'Vendor')
      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/test_proof.pdf').open,
        filename: 'w9_form.pdf',
        content_type: 'application/pdf'
      )
      vendor.update!(w9_status: :pending_review)
      assert vendor.w9_form.attached?

      W9Review.where(vendor_id: vendor.id).destroy_all

      assert_difference('W9Review.count') do
        post admin_vendor_w9_reviews_path(vendor), params: {
          w9_review: {
            reviewed_blob_id: vendor.w9_form.blob.id,
            status: 'approved',
            reviewed_at: Time.current.to_s
          }
        }
      end

      assert_redirected_to admin_vendor_path(vendor)
      assert_equal 'W9 review completed successfully', flash[:notice]

      vendor.reload
      assert_equal 'approved', vendor.w9_status
    rescue ActiveSupport::TestCase::Assertion => e
      Rails.logger.debug { "W9Review errors: #{@controller.instance_variable_get('@w9_review')&.errors&.full_messages}" }
      raise e
    end

    test 'should create rejected w9 review' do
      vendor = create(:vendor, type: 'Vendor')

      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      vendor.update!(w9_status: :pending_review)
      assert vendor.w9_form.attached?

      W9Review.where(vendor_id: vendor.id).destroy_all

      assert_difference('W9Review.count') do
        post admin_vendor_w9_reviews_path(vendor), params: {
          w9_review: {
            reviewed_blob_id: vendor.w9_form.blob.id,
            status: 'rejected',
            rejection_reason_code: 'address_mismatch',
            rejection_reason: "The address doesn't match our records",
            reviewed_at: Time.current.to_s
          }
        }
      end

      assert_redirected_to admin_vendor_path(vendor)
      assert_equal 'W9 review completed successfully', flash[:notice]

      vendor.reload
      assert_equal 'rejected', vendor.w9_status
    rescue ActiveSupport::TestCase::Assertion => e
      w9_review = @controller.instance_variable_get('@w9_review')
      if w9_review
        Rails.logger.debug { "W9Review validation errors: #{w9_review.errors.full_messages}" }
      else
        Rails.logger.debug 'W9Review instance variable is nil'
      end
      raise e
    end

    test 'should not create rejected w9 review without reason' do
      vendor = create(:vendor, type: 'Vendor')

      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      vendor.update!(w9_status: :pending_review)
      assert vendor.w9_form.attached?

      W9Review.where(vendor_id: vendor.id).destroy_all

      get new_admin_vendor_w9_review_path(vendor)
      assert_response :success

      assert_no_difference('W9Review.count') do
        post admin_vendor_w9_reviews_path(vendor), params: {
          w9_review: {
            reviewed_blob_id: vendor.w9_form.blob.id,
            status: 'rejected',
            rejection_reason: '',
            rejection_reason_code: ''
          }
        }
      end

      assert_response :unprocessable_content

      w9_review = @controller.instance_variable_get('@w9_review')
      assert_not_nil w9_review, 'W9Review instance variable shouldnt be nil'
      assert w9_review.errors.any?, 'W9Review should have validation errors'
    end

    test 'missing and invalid decisions retain the submitted document for a corrected retry' do
      vendor = create(:vendor, :with_w9)
      blob_id = vendor.w9_form.blob.id

      [nil, '', 'invalid_decision'].each do |status|
        assert_no_changes -> { [W9Review.count, Event.count, vendor.reload.w9_status] } do
          post admin_vendor_w9_reviews_path(vendor), params: { w9_review: { reviewed_blob_id: blob_id, status: status } }
        end
        assert_response :unprocessable_content
        assert_select "input[name='w9_review[reviewed_blob_id]'][type='hidden'][value='#{blob_id}']", count: 1
      end

      post admin_vendor_w9_reviews_path(vendor), params: { w9_review: { reviewed_blob_id: blob_id, status: 'approved' } }

      assert_redirected_to admin_vendor_path(vendor)
      assert_predicate vendor.reload, :w9_status_approved?
      assert_equal blob_id, vendor.w9_reviews.last.reviewed_blob_id
    end

    test 'should show w9 review' do
      vendor = create(:vendor, type: 'Vendor')

      # The show action requires an attached W9.
      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      review = create(:w9_review, vendor: vendor, admin: @admin)

      get admin_vendor_w9_review_path(vendor, review)
      assert_response :success
    end

    test 'review shows recorded delivery failure instead of claiming an email was sent' do
      vendor = create(:vendor, :with_w9)
      review = create(:w9_review, vendor: vendor, admin: @admin)
      notification = create(:notification, recipient: vendor, actor: @admin, notifiable: vendor, action: 'w9_approved',
                                           metadata: { w9_review_id: review.id })
      notification.mark_delivery_failed!(StandardError.new('Synthetic delivery failure'))

      get admin_vendor_w9_review_path(vendor, review)

      assert_response :success
      assert_select 'section[aria-label="W9 decision delivery"]', text: /#{Regexp.escape(DeliveryStatusPresenter.new(notification).label)}/
      assert_no_match(/Yes, email sent/, response.body)
    end

    test 'review delivery belongs to its decision rather than a later decision for the same vendor' do
      vendor = create(:vendor, :with_w9)
      first_review = create(:w9_review, vendor: vendor, admin: @admin)
      first_notification = create(:notification, recipient: vendor, actor: @admin, notifiable: vendor, action: 'w9_approved',
                                                 metadata: { w9_review_id: first_review.id })
      first_notification.mark_delivery_failed!(StandardError.new('Synthetic first-review delivery failure'))
      Vendors::ReplaceW9.call(vendor: vendor, file: Rack::Test::UploadedFile.new(file_fixture('sample_w9.pdf'), 'application/pdf'))
      second_review = create(:w9_review, vendor: vendor, admin: @admin)
      second_notification = create(:notification, recipient: vendor, actor: @admin, notifiable: vendor, action: 'w9_approved',
                                                  metadata: { w9_review_id: second_review.id })
      second_notification.record_delivery_queued!

      get admin_vendor_w9_review_path(vendor, first_review)

      assert_response :success
      assert_select 'section[aria-label="W9 decision delivery"] [data-delivery-status="failed"]', count: 1
      assert_select 'section[aria-label="W9 decision delivery"] [data-delivery-status="queued"]', count: 0

      get admin_vendor_w9_review_path(vendor, second_review)

      assert_response :success
      assert_select 'section[aria-label="W9 decision delivery"] [data-delivery-status="queued"]', count: 1
      assert_select 'section[aria-label="W9 decision delivery"] [data-delivery-status="failed"]', count: 0
    end

    test 'a rejection notice without a delivery outcome does not render an empty delivery heading' do
      vendor = create(:vendor, :with_w9)
      review = create(:w9_review, :rejected, vendor: vendor, admin: @admin)
      notification = create(:notification, recipient: vendor, actor: @admin, notifiable: vendor, action: 'w9_rejected',
                                           metadata: { w9_review_id: review.id, channel: 'email' })
      assert_equal 'unknown', DeliveryStatusPresenter.new(notification).status

      get admin_vendor_w9_review_path(vendor, review)

      assert_response :success
      assert_select 'section[aria-label="W9 decision delivery"]', count: 0
    end

    test 'should require admin authentication' do
      vendor = create(:vendor, type: 'Vendor')

      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      cookies.delete(:session_token)
      delete sign_out_path

      get new_admin_vendor_w9_review_path(vendor)
      assert_redirected_to sign_in_path
    end

    test 'should redirect if w9 form is missing even in test environment' do
      vendor_without_w9 = create(:vendor, type: 'Vendor')

      assert_not vendor_without_w9.w9_form.attached?

      get new_admin_vendor_w9_review_path(vendor_without_w9)

      assert_redirected_to admin_vendors_path
    end

    test 'should redirect if review not found with specific message' do
      vendor = create(:vendor, type: 'Vendor')

      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      get admin_vendor_w9_review_path(vendor, 999_999)
      assert_redirected_to admin_vendor_path(vendor)
      assert_equal 'Review not found', flash[:alert]
    end

    test 'should redirect if vendor not found' do
      get admin_vendor_w9_review_path(999_999, 1)
      assert_redirected_to admin_vendors_path
      assert_equal 'Vendor not found', flash[:alert]
    end

    test 'should not allow non-admin to review w9' do
      vendor = create(:vendor, type: 'Vendor')

      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      non_admin = create(:vendor, type: 'Vendor')

      delete sign_out_path
      sign_in_as(non_admin)

      get new_admin_vendor_w9_review_path(vendor)
      assert_redirected_to root_path
      assert_equal 'You are not authorized to perform this action', flash[:alert]
    end
  end
end
