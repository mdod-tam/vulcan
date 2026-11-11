# frozen_string_literal: true

require 'test_helper'

module Admin
  class ProductsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @admin = create(:admin)
      @product = create(:product, name: 'iPad Air', device_types: ['Tablet'])

      sign_in_as(@admin, bypass_mfa_enrollment: true)
    end

    def test_should_get_index
      get admin_products_path
      assert_response :success
    end

    def test_should_get_new
      vendor = create(:vendor, :approved)

      get new_admin_product_path

      assert_response :success
      assert_select "input[type=checkbox][name='product[vendor_ids][]'][value=?]", vendor.id.to_s
    end

    def test_should_create_product
      assert_difference('Product.count') do
        post admin_products_path, params: {
          product: {
            name: 'New Test Product',
            manufacturer: 'Test Manufacturer',
            model_number: 'TEST-001',
            description: 'Test Description',
            features: 'Test Features',
            compatibility_notes: 'Test Notes',
            documentation_url: 'https://example.com/docs',
            device_types: ['Smartphone']
          }
        }
      end
      assert_redirected_to admin_products_path
      assert_equal 'Product successfully created.', flash[:notice]
    end

    def test_should_show_product
      get admin_product_path(@product)
      assert_response :success
    end

    def test_should_get_edit
      get edit_admin_product_path(@product)
      assert_response :success
    end

    def test_should_update_product
      patch admin_product_path(@product), params: {
        product: {
          name: 'Updated iPad Air',
          description: 'Updated description'
        }
      }
      assert_redirected_to admin_products_path
      assert_equal 'Product successfully updated.', flash[:notice]
      @product.reload
      assert_equal 'Updated iPad Air', @product.name
    end

    def test_should_archive_product
      post archive_admin_product_path(@product)
      assert_redirected_to admin_products_path
      @product.reload
      assert_not_nil @product.archived_at
      assert_equal 'Product archived.', flash[:notice]
    end

    def test_should_unarchive_product
      @product.update!(archived_at: Time.current)
      post unarchive_admin_product_path(@product)
      assert_redirected_to admin_products_path
      @product.reload
      assert_nil @product.archived_at
      assert_equal 'Product unarchived.', flash[:notice]
    end

    def test_archive_of_a_product_that_fails_validation_redirects_with_the_failure_alert
      @product.update_column(:manufacturer, nil)

      post archive_admin_product_path(@product)

      assert_redirected_to admin_products_path
      assert_equal I18n.t('admin.products.archive.product_archive_fail'), flash[:alert]
      assert_nil @product.reload.archived_at
    end

    def test_unarchive_of_a_product_that_fails_validation_redirects_with_the_failure_alert
      archived_at = 1.day.ago.change(usec: 0)
      @product.update_columns(manufacturer: nil, archived_at: archived_at)

      post unarchive_admin_product_path(@product)

      assert_redirected_to admin_products_path
      assert_equal I18n.t('admin.products.unarchive.product_unarchive_fail'), flash[:alert]
      assert_equal archived_at, @product.reload.archived_at
    end

    def test_should_filter_by_device_type
      create(:product, name: 'Pixel Phone', device_types: ['Smartphone'])

      get admin_products_path, params: { device_types: ['Tablet'] }

      assert_response :success
      assert_includes response.body, 'iPad Air'
      assert_not_includes response.body, 'Pixel Phone'
    end

    def test_filter_matches_each_submitted_device_type_as_one_literal_name
      create(:product, name: 'Pixel Phone', device_types: ['Smartphone'])

      get admin_products_path, params: { device_types: ['Tablet, Smartphone'] }
      assert_response :success
      assert_not_includes response.body, 'iPad Air', 'a comma must not split one submitted type into two'
      assert_not_includes response.body, 'Pixel Phone'

      get admin_products_path, params: { device_types: ['Tab"let'] }
      assert_response :success
      assert_not_includes response.body, 'iPad Air', 'a quote must not change which types are searched'
    end

    def test_non_admin_cannot_access
      @user = create(:constituent)
      sign_in_for_integration_test(@user)

      get admin_products_path
      assert_redirected_to root_path
      assert_equal I18n.t('alerts.unauthorized_action'), flash[:alert]
    end

    def test_unauthenticated_user_cannot_access
      sign_out

      get admin_products_path
      assert_redirected_to sign_in_path
      assert_equal 'Please sign in to continue', flash[:alert]
    end

    def teardown
      Current.reset
    end
  end
end
