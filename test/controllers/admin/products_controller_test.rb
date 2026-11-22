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

    test 'accessories use one category and shared disability groups without repeating products' do
      Product.by_device_types(['Accessory']).find_each { |product| product.update!(eligible_disability_groups: ['speech']) }
      shared = create(:product, category: 'alerters_accessories_equipment', device_types: %w[Accessory Signaler Accessory],
                                eligible_disability_groups: %w[deafblind deaf deaf])
      deafblind = create(:product, category: 'alerters_accessories_equipment', device_types: ['Accessory'],
                                   eligible_disability_groups: ['deafblind'])
      deaf = create(:product, category: 'alerters_accessories_equipment', device_types: ['Accessory'], eligible_disability_groups: ['deaf'])
      archived = create(:product, :archived, category: 'alerters_accessories_equipment', device_types: ['Accessory'],
                                             eligible_disability_groups: ['deafblind'])

      get admin_products_path, params: { device_types: ['Accessory'], disability_groups: ['deafblind'] }
      assert_response :success
      assert_select '[data-catalog-category]', count: 1
      assert_select '[data-catalog-category=alerters_accessories_equipment] > summary', text: /2 products on this page/
      assert_select '#products_list tbody tr', count: 2
      assert_select "#product_#{shared.id}", count: 1
      assert_select "#product_#{deafblind.id}", count: 1
      assert_select '[data-disability-groups="deaf deafblind"] h3', text: 'Deaf, DeafBlind'
      assert_select '[data-disability-groups=deafblind] h3', text: 'DeafBlind'
      assert_select "#product_#{deaf.id}, #product_#{archived.id}", count: 0

      get admin_products_path, params: { device_types: ['Accessory'], disability_groups: %w[deaf deafblind], include_discontinued: '1' }
      assert_select '#products_list tbody tr', count: 4
      assert_select "#product_#{shared.id}", count: 1
      assert_select "#product_#{deaf.id}, #product_#{archived.id}", count: 2

      get admin_products_path, params: { device_types: ['Accessory'], disability_groups: ['mobility'] }
      assert_select '#products_list tbody tr', count: 0
      assert_select '#products_list', text: /No products match these filters\./
    end

    test 'catalog search matches manufacturer model and name without losing the other filters' do
      products = [
        create(:product, manufacturer: 'Searchco', model_number: 'MAKER-001', name: 'Manufacturer match',
                         device_types: ['Tablet'], eligible_disability_groups: ['deafblind']),
        create(:product, manufacturer: 'Other manufacturer', model_number: 'SEARCHCO-001', name: 'Model match',
                         device_types: ['Tablet'], eligible_disability_groups: ['deafblind']),
        create(:product, manufacturer: 'Another manufacturer', model_number: 'NAME-001', name: 'Searchco controls',
                         device_types: ['Tablet'], eligible_disability_groups: ['deafblind'])
      ]
      create(:product, manufacturer: 'Searchco', device_types: ['Tablet'], eligible_disability_groups: ['mobility'])
      create(:product, manufacturer: 'Searchco', category: 'alerters_accessories_equipment',
                       device_types: ['Accessory'], eligible_disability_groups: ['deafblind'])
      create(:product, :archived, manufacturer: 'Searchco', device_types: ['Tablet'], eligible_disability_groups: ['deafblind'])

      get admin_products_path, params: { q: ' sEaRcHcO ', device_types: ['Tablet'], disability_groups: ['deafblind'] }

      assert_response :success
      assert_equal products.map { |product| "product_#{product.id}" }.sort, css_select('#products_list tbody tr').pluck('id').sort
      assert_select '#q[value=sEaRcHcO]'
      assert_select '#device_type_tablet[checked]'
      assert_select '#disability_group_deafblind[checked]'
    end

    test 'catalog search treats percent and underscore as literal characters' do
      literal = create(:product, name: 'Literal 100%_test')
      create(:product, name: 'Literal 100percentXtest')

      get admin_products_path, params: { q: '100%_' }

      assert_response :success
      assert_select '#products_list tbody tr', count: 1
      assert_select "#product_#{literal.id}"
    end

    test 'catalog sort allows manufacturer or model with stable name and id ties' do
      first = create(:product, manufacturer: 'A Sortcatalog', model_number: 'Z', name: 'Sortcatalog shared')
      second = create(:product, manufacturer: 'A Sortcatalog', model_number: 'Y', name: 'Sortcatalog shared')
      third = create(:product, manufacturer: 'B Sortcatalog', model_number: 'A', name: 'Sortcatalog beta')
      fourth = create(:product, manufacturer: 'C Sortcatalog', model_number: 'A', name: 'Sortcatalog beta')
      fifth = create(:product, manufacturer: 'Z Sortcatalog', model_number: 'A', name: 'Sortcatalog alpha')

      expected = {
        nil => [first, second, third, fourth, fifth],
        'model' => [fifth, third, fourth, second, first],
        'model_number DESC' => [first, second, third, fourth, fifth]
      }
      expected.each do |sort, products|
        get admin_products_path, params: { q: 'sortcatalog', sort: }

        assert_response :success
        assert_equal products.map { |product| "product_#{product.id}" }, css_select('#products_list tbody tr').pluck('id')
        assert_select '#sort option[selected][value=?]', sort == 'model' ? 'model' : 'manufacturer'
      end
    end

    test 'catalog pagination retains search sort device type disability and discontinued filters' do
      Product.by_device_types(['Accessory']).find_each { |product| product.update!(eligible_disability_groups: ['speech']) }
      products = Array.new(Pagy::DEFAULT[:limit] + 1) do |index|
        create(:product, name: format('Paged accessory %03d', index), model_number: format('PAGED-%03d', index), category: 'alerters_accessories_equipment',
                         device_types: ['Accessory'], eligible_disability_groups: ['deafblind'])
      end
      products.last.archive!
      excluded = create(:product, name: 'Paged mobility accessory', category: 'alerters_accessories_equipment',
                                  device_types: ['Accessory'], eligible_disability_groups: ['mobility'])
      unmatched = create(:product, name: 'Other accessory', model_number: 'OTHER-001', category: 'alerters_accessories_equipment',
                                   device_types: ['Accessory'], eligible_disability_groups: ['deafblind'])
      get admin_products_path, params: { q: 'pAgEd', sort: 'model', device_types: ['Accessory'], disability_groups: ['deafblind'], include_discontinued: '1' }
      assert_response :success
      assert_select '#products_list tbody tr', count: Pagy::DEFAULT[:limit]
      next_page = css_select('nav[aria-label=Products] a[rel=next]').sole['href']
      get next_page
      assert_response :success
      assert_select 'nav[aria-label=Products] a[rel=prev]'
      assert_select '#device_type_accessory[checked]'
      assert_select '#disability_group_deafblind[checked]'
      assert_select '#include_discontinued[checked]'
      assert_select '#q[value=pAgEd]'
      assert_select '#sort option[value=model][selected]'
      assert_select '#products_list tbody tr', count: 1
      assert_select "#product_#{products.last.id}", text: /Discontinued/
      assert_select "#product_#{excluded.id}, #product_#{unmatched.id}", count: 0
    end

    def test_should_get_new
      get new_admin_product_path

      assert_response :success
      assert_product_editor('New Product', admin_products_path)
      assert_select "input[type=checkbox][name='product[eligible_disability_groups][]']", Product::PROGRAM_GROUPS.size
      assert_select "input[name='product[vendor_ids][]']", count: 0
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
            device_types: ['', 'Smartphone', 'Hands-free Device'], category: 'devices', model_confirmed: true,
            eligible_disability_groups: ['', 'deaf', 'mobility'], msrp: '1234.56'
          }
        }
      end
      assert_redirected_to admin_products_path
      assert_equal 'Product successfully created.', flash[:notice]
      product = Product.find_by!(model_number: 'TEST-001')
      assert_equal({
                     'name' => 'New Test Product', 'manufacturer' => 'Test Manufacturer', 'model_number' => 'TEST-001',
                     'description' => 'Test Description', 'features' => 'Test Features', 'compatibility_notes' => 'Test Notes',
                     'documentation_url' => 'https://example.com/docs', 'category' => 'devices', 'model_confirmed' => true,
                     'device_types' => ['Smartphone', 'Hands-free Device'], 'eligible_disability_groups' => %w[deaf mobility],
                     'msrp' => BigDecimal('1234.56')
                   }, product.attributes.slice('name', 'manufacturer', 'model_number', 'description', 'features', 'compatibility_notes',
                                               'documentation_url', 'category', 'model_confirmed', 'device_types', 'eligible_disability_groups', 'msrp'))
      assert product.available?
    end

    test 'a draft can omit its manufacturer model and unknown MSRP until those details are verified' do
      assert_difference('Product.count') do
        post admin_products_path, params: { product: {
          name: 'Draft tablet', manufacturer: '', model_number: '', msrp: '', category: 'devices', model_confirmed: '0',
          device_types: ['Tablet'], eligible_disability_groups: ['deafblind']
        } }
      end
      assert_redirected_to admin_products_path
      product = Product.find_by!(name: 'Draft tablet')
      assert_nil product.manufacturer
      assert_nil product.model_number
      assert_nil product.msrp
      assert_not product.available?
      assert_not Product.available.exists?(product.id)

      patch admin_product_path(product), params: { product: { model_confirmed: '1' } }
      assert_response :unprocessable_content
      assert_product_editor('Edit Product', admin_product_path(product))
      assert_select '#product_model_confirmed[checked]'
      assert_select 'li', text: "Manufacturer can't be blank"
      assert_select 'li', text: "Model number can't be blank"
      assert_not product.reload.model_confirmed?

      patch admin_product_path(product), params: { product: {
        manufacturer: 'Known manufacturer', model_number: 'DB-001', model_confirmed: '1', msrp: ''
      } }
      assert_redirected_to admin_products_path
      assert product.reload.available?
      assert_nil product.msrp
    end

    test 'MSRP accepts the database maximum and rejects an amount above it in the form' do
      patch admin_product_path(@product), params: { product: { msrp: '9999999999.99' } }
      assert_redirected_to admin_products_path
      assert_equal BigDecimal('9999999999.99'), @product.reload.msrp

      patch admin_product_path(@product), params: { product: { msrp: '10000000000' } }
      assert_response :unprocessable_content
      assert_select 'li', text: /must be less than or equal to/
      assert_equal BigDecimal('9999999999.99'), @product.reload.msrp
    end

    def test_should_show_product
      get admin_product_path(@product)
      assert_response :success
    end

    test 'invalid category types and program groups stay visible and removable on retry' do
      submitted = {
        name: 'Invalid classification retry', category: 'unknown_category',
        device_types: ['Unknown device type'], eligible_disability_groups: ['unknown_group'],
        manufacturer: 'Retry manufacturer', model_number: 'RETRY-001', model_confirmed: '1', msrp: '250.25',
        description: 'Keep this description', features: 'Keep these features', compatibility_notes: 'Keep these notes',
        documentation_url: 'https://example.com/retry-docs'
      }
      assert_no_difference 'Product.count' do
        post admin_products_path, params: { product: submitted }
      end
      assert_response :unprocessable_content
      assert_select '#product_category option[value=unknown_category][selected]', text: 'unknown_category (invalid category)'
      assert_select "input[name='product[device_types][]'][value='Unknown device type'][checked]"
      assert_select "input[name='product[eligible_disability_groups][]'][value='unknown_group'][checked]"
      assert_select 'li', text: /Category/
      assert_select 'li', text: /Device types/
      assert_select 'li', text: /Eligible disability groups/
      assert_product_editor('New Product', admin_products_path)
      %w[name manufacturer model_number documentation_url].each do |field|
        assert_select "input[name='product[#{field}]'][value=?]", submitted.fetch(field.to_sym)
      end
      assert_select '#product_msrp[value="250.25"]'
      assert_select '#product_model_confirmed[checked]'
      %w[description features compatibility_notes].each do |field|
        assert_select "textarea[name='product[#{field}]']", text: submitted.fetch(field.to_sym)
      end

      assert_no_difference('Product.count') { post admin_products_path, params: { product: submitted } }
      assert_response :unprocessable_content
      post admin_products_path, params: { product: submitted.merge(category: 'alerters_accessories_equipment',
                                                                   device_types: ['Accessory'], eligible_disability_groups: ['deafblind']) }
      assert_redirected_to admin_products_path
      product = Product.find_by!(model_number: 'RETRY-001')
      assert_equal ['Accessory'], product.device_types
      assert_equal ['deafblind'], product.eligible_disability_groups
      assert_equal 'Keep these features', product.features
      assert_equal BigDecimal('250.25'), product.msrp
    end

    def test_should_get_edit
      get edit_admin_product_path(@product)
      assert_response :success
      assert_product_editor('Edit Product', admin_product_path(@product))
    end

    def test_should_update_product
      patch admin_product_path(@product), params: {
        product: {
          name: 'Updated iPad Air',
          manufacturer: 'Updated manufacturer', model_number: 'UPDATED-002', msrp: '', model_confirmed: '0',
          description: 'Updated description', features: 'Updated features', compatibility_notes: 'Updated compatibility',
          documentation_url: 'https://example.com/updated-docs', category: 'alerters_accessories_equipment',
          device_types: %w[Accessory Signaler], eligible_disability_groups: %w[speech mobility]
        }
      }
      assert_redirected_to admin_products_path
      assert_equal 'Product successfully updated.', flash[:notice]
      @product.reload
      assert_equal 'Updated iPad Air', @product.name
      assert_equal 'Updated manufacturer', @product.manufacturer
      assert_equal 'UPDATED-002', @product.model_number
      assert_nil @product.msrp
      assert_not @product.model_confirmed?
      assert_equal 'Updated description', @product.description
      assert_equal 'Updated features', @product.features
      assert_equal 'Updated compatibility', @product.compatibility_notes
      assert_equal 'https://example.com/updated-docs', @product.documentation_url
      assert_equal 'alerters_accessories_equipment', @product.category
      assert_equal %w[Accessory Signaler], @product.device_types
      assert_equal %w[speech mobility], @product.eligible_disability_groups
    end

    def test_should_archive_product
      post archive_admin_product_path(@product)
      assert_redirected_to admin_products_path
      @product.reload
      assert_not_nil @product.archived_at
      assert_equal I18n.t('admin.products.archive.product_archive_pass'), flash[:notice]
    end

    def test_should_unarchive_product
      @product.update!(archived_at: Time.current)
      post unarchive_admin_product_path(@product)
      assert_redirected_to admin_products_path
      @product.reload
      assert_nil @product.archived_at
      assert_equal I18n.t('admin.products.unarchive.product_unarchive_pass'), flash[:notice]
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

    private

    def assert_product_editor(title, action)
      assert_select 'h1', count: 1, text: title
      assert_select 'h1#form-title', text: title
      assert_select 'main main', count: 0
      assert_select '.min-h-screen', count: 0
      assert_select "a[href='#{admin_dashboard_path}']", text: 'Back to Dashboard'
      assert_select "a[href='#{admin_products_path}']", text: 'Back to Products'
      assert_select "a[href='#{admin_products_path}']", text: 'Cancel'
      assert_select "form[action='#{action}'][data-controller~=product-classification]"
      assert_select "form[action='#{action}'][aria-labelledby=form-title]" do
        assert_select 'select#product_category.form-select[required]'
        assert_select '#product_name[required]'
        assert_select 'fieldset legend', text: 'Disability groups (required)'
        assert_select 'textarea.form-textarea', count: 3
        controls = css_select('input:not([type=hidden]):not([type=submit]), select, textarea')
        ids = controls.pluck('id')
        assert ids.all?(&:present?), 'Every visible product control needs an ID'
        assert_equal ids.uniq, ids, 'Visible product control IDs must be unique'
        controls.each do |control|
          id = control['id']
          assert css_select('label').any? { |label| label['for'] == id || label.css('input').any? { |input| input['id'] == id } },
                 "Missing label for #{id}"
        end
      end
    end
  end
end
