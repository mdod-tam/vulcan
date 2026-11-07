# frozen_string_literal: true

require 'test_helper'

# A page parameter is part of the URL, so people edit it and stale links keep an old one. Every paginated list shows
# its first page for a parameter that is not a positive integer, instead of raising Pagy::VariableError and answering 500.
class ListPageParameterTest < ActionDispatch::IntegrationTest
  INVALID_PAGES = %w[abc 0 -2].freeze

  # Each list: the factory for the signed-in user, and the path to request (evaluated in the test, after sign-in).
  LISTS = {
    'admin vouchers' => [:admin, -> { admin_vouchers_path }],
    'admin products' => [:admin, -> { admin_products_path }],
    'admin vendors' => [:admin, -> { admin_vendors_path }],
    'admin invoices' => [:admin, -> { admin_invoices_path }],
    'admin vendor W-9 reviews' => [:admin, -> { admin_vendor_w9_reviews_path(create(:vendor)) }],
    'admin policy changes' => [:admin, -> { changes_admin_policies_path }],
    'admin dashboard assigned notes' => [:admin, -> { admin_dashboard_path }],
    'notifications' => [:constituent, -> { notifications_path }],
    'trainer training sessions' => [:trainer, -> { trainers_training_sessions_path }],
    'vendor invoices' => [:vendor_user, -> { vendor_portal_invoices_path }],
    'vendor transactions' => [:vendor_user, -> { vendor_portal_transactions_path }]
  }.freeze

  setup do
    ensure_system_audit_actor!
  end

  LISTS.each do |name, (role, path)|
    INVALID_PAGES.each do |page|
      test "#{name} shows its first page for page=#{page}" do
        sign_in_for_integration_test(create(role))

        get instance_exec(&path), params: { page: page }

        assert_response :success
      end
    end
  end
end
