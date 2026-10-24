# frozen_string_literal: true

require 'test_helper'

module Admin
  class ProductResourcesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      @product = create(:product, :archived)
      sign_in_for_integration_test(@admin)
    end

    test 'admin manages resources on archived products and the product shows public authoring guidance' do
      get new_admin_product_product_resource_path(@product)
      assert_response :success
      assert_includes response.body, 'Do not include personal or session information'
      assert_select 'input[type=file][accept=".pdf,application/pdf"]'
      assert_select '[data-document-upload-scans-url-value=?]', document_scans_path
      assert_select '#product_resource_document' do |inputs|
        assert_equal %w[pdf-help product_resource_document_status], inputs.sole['aria-describedby'].split
      end
      assert_difference 'ProductResource.count', 1 do
        post admin_product_product_resources_path(@product), params: { product_resource: link_attributes }
      end
      resource = @product.product_resources.sole
      assert_redirected_to admin_product_path(@product)
      get admin_product_path(@product)
      assert_select 'a', text: 'Add resource'
      assert_select 'p', text: /Guide · English · URL/
      assert_select 'a[href=?]', edit_admin_product_product_resource_path(@product, resource) do |links|
        assert_includes links.sole['aria-label'], 'Edit resource: Guide'
        assert_includes links.sole['aria-label'], @product.name
      end
      assert_select 'form[action=?] button', admin_product_product_resource_path(@product, resource) do |buttons|
        assert_includes buttons.sole['aria-label'], 'Delete resource: Guide'
        assert_includes buttons.sole['aria-label'], @product.name
      end
      patch admin_product_product_resource_path(@product, resource), params: { product_resource: link_attributes.merge(title: 'Updated guide') }
      assert_redirected_to admin_product_path(@product)
      assert_equal 'Updated guide', resource.reload.title
      assert_difference 'ProductResource.count', -1 do
        delete admin_product_product_resource_path(@product, resource)
      end
      assert Event.exists?(action: 'product_resource_deleted', auditable: @product)
    end

    test 'invalid source retains attempted title language URL and accepts unchanged then corrected retries' do
      attributes = link_attributes.merge(title: 'Guía intentada', locale: 'es', url: 'ftp://example.org/guide')
      2.times do
        assert_no_difference 'ProductResource.count' do
          post admin_product_product_resources_path(@product), params: { product_resource: attributes }
        end
        assert_response :unprocessable_content
        assert_select 'input[name="product_resource[title]"][value="Guía intentada"]'
        assert_select 'select[name="product_resource[locale]"] option[selected][value="es"]'
        assert_select 'input[name="product_resource[url]"][value="ftp://example.org/guide"]'
      end
      post admin_product_product_resources_path(@product), params: { product_resource: attributes.merge(url: 'https://example.org/guide') }
      assert_redirected_to admin_product_path(@product)
      assert_equal 'es', @product.product_resources.sole.locale
    end

    test 'accepted PDF is retained across validation failure and can be submitted unchanged with corrected title' do
      blob = cleared_pdf
      attributes = { title: '', locale: 'es', source: 'pdf', document_signed_id: blob.signed_id }
      post admin_product_product_resources_path(@product), params: { product_resource: attributes }
      assert_response :unprocessable_content
      assert_select 'input[type=hidden][name="product_resource[document_signed_id]"]'
      assert_select 'select[name="product_resource[source]"] option[selected][value="pdf"]'
      post admin_product_product_resources_path(@product), params: { product_resource: attributes.merge(title: 'Guía PDF') }
      assert_redirected_to admin_product_path(@product)
      assert_equal blob.id, @product.product_resources.sole.document.blob.id
    end

    test 'PDF errors retain the help error and live upload status descriptions together' do
      assert_no_difference 'ProductResource.count' do
        post admin_product_product_resources_path(@product),
             params: { product_resource: { title: 'Attempted PDF', locale: 'en', source: 'pdf', document_signed_id: 'invalid-reference' } }
      end

      assert_response :unprocessable_content
      assert_select '#product_resource_document[aria-invalid=true]' do |inputs|
        descriptions = inputs.sole['aria-describedby'].split
        assert_equal %w[pdf-help save-resource-document-error product_resource_document_status], descriptions
      end
      %w[pdf-help save-resource-document-error product_resource_document_status].each { |id| assert_select "##{id}", count: 1 }
      assert_select '#product_resource_document_status[role=status]'
    end

    test 'a failed link to PDF switch preserves the active link and all attempted form state until corrected' do
      resource = create(:product_resource, product: @product)
      blob = cleared_pdf
      attributes = { title: '', locale: 'es', source: 'pdf', url: resource.url, document_signed_id: blob.signed_id }
      patch admin_product_product_resource_path(@product, resource), params: { product_resource: attributes }
      assert_response :unprocessable_content
      assert_select 'input[name="product_resource[url]"][value="https://example.com/guide"]'
      assert_select 'select[name="product_resource[source]"] option[selected][value="pdf"]'
      assert_select 'input[name="product_resource[document_signed_id]"]'
      assert_equal 'https://example.com/guide', resource.reload.url
      assert_not resource.document.attached?
      patch admin_product_product_resource_path(@product, resource), params: { product_resource: attributes.merge(title: 'Guía PDF') }
      assert_redirected_to admin_product_path(@product)
      assert_nil resource.reload.url
      assert_equal blob.id, resource.document.blob.id
    end

    test 'nested writes cannot select a resource from a different product' do
      resource = create(:product_resource)
      patch admin_product_product_resource_path(@product, resource), params: { product_resource: link_attributes }
      assert_response :not_found
      delete admin_product_product_resource_path(@product, resource)
      assert_response :not_found
      assert ProductResource.exists?(resource.id)
    end

    test 'constituents cannot create update or delete public resources' do
      resource = create(:product_resource, product: @product)
      sign_in_for_integration_test(create(:constituent))
      assert_no_difference 'ProductResource.count' do
        post admin_product_product_resources_path(@product), params: { product_resource: link_attributes }
      end
      assert_response :redirect
      patch admin_product_product_resource_path(@product, resource), params: { product_resource: link_attributes.merge(title: 'Unauthorized') }
      assert_response :redirect
      delete admin_product_product_resource_path(@product, resource)
      assert_response :redirect
      assert_equal 'Getting started', resource.reload.title
    end

    private

    def cleared_pdf
      scanned_upload(fixture_file_upload('medical_certification_valid.pdf', 'application/pdf'),
                     user: @admin, purpose: :product_resource, slot: 'document')
    end

    def link_attributes
      { title: 'Guide', locale: 'en', source: 'url', url: 'https://example.org/guide' }
    end
  end
end
