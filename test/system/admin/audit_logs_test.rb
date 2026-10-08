# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class AuditLogsTest < ApplicationSystemTestCase
    setup do
      Capybara.reset_sessions!

      @admin = users(:admin_david)

      @application = create(:application,
                            user: users(:confirmed_user),
                            status: 'in_progress',
                            household_size: 2,
                            annual_income: 30_000,
                            maryland_resident: true,
                            self_certify_disability: true,
                            income_proof_status: 'not_reviewed',
                            residency_proof_status: 'not_reviewed')

      @original_application_host = ENV.fetch('APPLICATION_HOST', nil)

      attach_lightweight_proof(@application, :income_proof)
      attach_lightweight_proof(@application, :residency_proof)

      @application.reload

      ENV['APPLICATION_HOST'] = 'example.com'

      # Each test signs in after setup.
    end

    teardown do
      begin
        if has_selector?('#incomeProofReviewModal', visible: true)
          within('#incomeProofReviewModal') do
            click_button 'Close' if has_button?('Close')
          end
        end

        if has_selector?('#residencyProofReviewModal', visible: true)
          within('#residencyProofReviewModal') do
            click_button 'Close' if has_button?('Close')
          end
        end
      rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError
        Capybara.reset_sessions!
      end

      ENV['APPLICATION_HOST'] = @original_application_host

      Capybara.reset_sessions!
    end

    test 'audit logs correctly show proof review actions without duplicates' do
      system_test_sign_in(@admin)
      visit_admin_application_with_retry(@application, user: @admin)

      assert_selector '#attachments-section', wait: 15

      click_review_proof_and_wait('income', timeout: 20)

      within '#incomeProofReviewModal' do
        assert_selector 'button', text: 'Approve'
        accept_confirm { click_button 'Approve' }
      end

      assert_notification('Income proof approved successfully.')

      assert_no_selector '#incomeProofReviewModal', visible: true

      audit_logs_section = first('#audit-logs', visible: true)
      within audit_logs_section do
        assert_text 'Admin Review'
        assert_text @admin.full_name
        assert_text 'Income proof approved'
        assert_no_text 'Admin Income proof approved'

        assert_selector 'tbody tr'
        income_approved_rows = all('tbody tr').select do |tr|
          tr.text.include?('Income proof') && tr.text.include?('approved')
        end
        assert_equal 1, income_approved_rows.count, 'Expected only one entry for Income proof approval'
      end
    end
  end
end
