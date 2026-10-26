# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class ProductsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = create(:constituent)
      @application = create(:application, :approved, :with_all_proofs, user: @user)
      @product = create(:product, :archived, name: 'Known historical model')
      purchase = create(:voucher_transaction, voucher: create(:voucher, application: @application))
      purchase.voucher_transaction_products.create!(product: @product, quantity: 1)
      sign_in_for_integration_test(@user)
    end

    test 'existing devices aliases retain their destinations' do
      get '/constituent_portal/devices'
      assert_redirected_to constituent_portal_products_path
      get "/constituent_portal/devices/#{@product.id}"
      assert_redirected_to constituent_portal_product_path(@product)
    end

    test 'devices and details agree on voucher evidence while user catalog membership grants nothing' do
      unrelated = create(:product, name: 'Catalog membership only')
      @user.products << unrelated
      get constituent_portal_products_path
      assert_response :success
      assert_select 'a[href=?]', constituent_portal_product_path(@product), text: /Known historical model/
      assert_select 'li', text: /Purchased with voucher/
      assert_not_includes response.body, unrelated.name
      get constituent_portal_product_path(@product)
      assert_response :success
      assert_select 'h1', text: /Known historical model/
      get constituent_portal_product_path(unrelated)
      assert_response :not_found
    end

    test 'a guardian sees only current managed applications in separate beneficiary groups' do
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)
      managed = create(:application, :approved, :with_all_proofs, user: dependent, managing_guardian: @user)
      managed_product = create(:product, name: 'Managed device')
      create(:equipment_item, application: managed, product: managed_product, shipped_at: Date.current, tracking_number: 'Sent')
      unrelated = create(:application, :approved, :with_all_proofs)
      unrelated_item = create(:equipment_item, application: unrelated, shipped_at: Date.current, tracking_number: 'Private')
      get constituent_portal_products_path
      assert_select 'h2', text: "Devices for #{@user.full_name}"
      assert_select 'h2', text: "Devices for #{dependent.full_name}"
      assert_select 'a[href=?]', constituent_portal_product_path(managed_product)
      assert_not_includes response.body, unrelated_item.product.name
      get constituent_portal_product_path(unrelated_item.product)
      assert_response :not_found

      other_guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: other_guardian, dependent_user: dependent)
      managed.update!(managing_guardian: other_guardian)
      get constituent_portal_product_path(managed_product)
      assert_response :not_found
    end

    test 'the authenticated viewer language selects guidance without an explicit locale parameter' do
      @user.update!(locale: 'es')
      create(:product_resource, product: @product, title: 'English setup', locale: 'en')
      create(:product_resource, product: @product, title: 'Guía en español', locale: 'es')

      get constituent_portal_product_path(@product)

      assert_response :success
      assert_select 'h2', text: /\AGuías de .*#{Regexp.escape(@product.name)}/
      assert_select 'h3', text: 'inglés · Otro idioma'
      assert_operator response.body.index('Guía en español'), :<, response.body.index('English setup')
    end

    test 'unsupported locale requests use the authenticated supported locale and unsupported stored locales use the default' do
      @user.update!(locale: 'es')
      get constituent_portal_product_path(@product, locale: 'unsupported')
      assert_response :success
      assert_select 'h2', text: /\AGuías de .*#{Regexp.escape(@product.name)}/

      @user.update!(locale: 'unsupported')
      get constituent_portal_product_path(@product)
      assert_response :success
      assert_select 'h2', text: /\AGuides for .*#{Regexp.escape(@product.name)}/
    end

    test 'resources prefer exact language and label alternatives and external navigation' do
      create(:product_resource, product: @product, title: 'English setup', locale: 'en')
      create(:product_resource, product: @product, title: 'Guía en español', locale: 'es')
      get constituent_portal_product_path(@product, locale: 'es')
      assert_response :success
      assert_operator response.body.index('Guía en español'), :<, response.body.index('English setup')
      assert_select 'h3', text: 'inglés · Otro idioma'
      assert_select 'a[target="_blank"][rel="noopener noreferrer"]', text: /Guía en español/ do |links|
        assert_includes links.sole.text, @product.name
        assert_includes links.sole.text, 'español'
        assert_includes links.sole.text, 'enlace externo'
        assert_includes links.sole.text, 'pestaña nueva'
      end
      assert_select 'section[aria-labelledby]' do |sections|
        guidance = sections.find { |section| section.at_css('h2')&.text&.include?(@product.name) }
        assert guidance, 'The guidance region must be named by its exact product heading'
        labels = guidance['aria-labelledby'].split.map { |id| guidance.at_css("##{id}")&.text }
        assert_includes labels.join(' '), @product.name
      end
      assert_includes response.body, 'se abre en una pestaña nueva'
    end

    test 'missing preferred language and wholly empty resources have distinct copy' do
      create(:product_resource, product: @product, title: 'English only', locale: 'en')
      get constituent_portal_product_path(@product, locale: 'es')
      assert_includes response.body, 'No hay guías en español'
      @product.product_resources.destroy_all
      get constituent_portal_product_path(@product)
      assert_includes response.body, 'No product guides have been added yet.'
    end

    test 'an empty device list has useful guidance and training alone creates no device membership' do
      other = create(:constituent)
      application = create(:application, :approved, user: other)
      session = create(:training_session, :completed, application: application)
      sign_in_for_integration_test(other)
      get constituent_portal_products_path
      assert_select 'h2', text: 'No recorded devices yet'
      assert_not_includes response.body, session.product_trained_on.name
      get constituent_portal_product_path(session.product_trained_on)
      assert_response :not_found
    end

    test 'public PDF proxy link contains no application identity and exact product resources do not spread by device type' do
      resource = @product.product_resources.new(title: 'PDF setup', locale: 'en')
      admin = create(:admin)
      upload = Rack::Test::UploadedFile.new(file_fixture('medical_certification_valid.pdf'), 'application/pdf', original_filename: 'guide.pdf')
      blob = scanned_upload(upload, user: admin, purpose: :product_resource, slot: 'document')
      assert ProductResources::Writer.new(resource: resource, actor: admin).save(
        attributes: { title: 'PDF setup', locale: 'en' }, source: 'pdf', document: blob
      )
      get constituent_portal_product_path(@product)
      assert_select 'a[href*="/rails/active_storage/blobs/proxy/"]', text: /PDF setup/ do |links|
        assert_not_includes links.first['href'], 'application'
        assert_includes links.first['href'], 'disposition=attachment'
        assert_includes links.first.text, @product.name
        assert_includes links.first.text, 'PDF download'
        assert_includes links.first.text, ApplicationController.helpers.number_to_human_size(blob.byte_size)
      end
      other_product = create(:product, device_types: @product.device_types)
      create(:equipment_item, application: @application, product: other_product, shipped_at: Date.current, tracking_number: 'Other')
      get constituent_portal_product_path(other_product)
      assert_not_includes response.body, 'PDF setup'
    ensure
      upload&.tempfile&.close
    end
  end
end
