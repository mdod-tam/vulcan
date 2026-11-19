# frozen_string_literal: true

require 'test_helper'

module Admin
  class MileageRatesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_as(@admin, bypass_mfa_enrollment: true)
    end

    test 'policies leave rates unset until an effective date and exact amount are entered and retain invalid input for correction' do
      assert_no_difference 'MileageRate.count' do
        get admin_policies_path
      end
      assert_response :success
      assert_select '#mileage-rates h2', text: 'Mileage reimbursement rates'
      assert_select "form[action='#{admin_mileage_rates_path}'] input[name='mileage_rate[dollars_per_mile]']" do |inputs|
        assert_empty inputs.sole['value'].to_s
      end

      2.times do
        assert_no_difference ['MileageRate.count', 'Event.count'] do
          post admin_mileage_rates_path, params: { mileage_rate: { effective_on: '07/01/2026', dollars_per_mile: '0.7251' } }
        end
        assert_response :unprocessable_content
        assert_select '#mileage-rates [role=alert]', text: /no more than three decimal places/
        assert_select "form[action='#{admin_mileage_rates_path}'] input[name='mileage_rate[dollars_per_mile]'][value='0.7251']"
        assert_select "form[action='#{admin_mileage_rates_path}'] input[name='mileage_rate[effective_on]'][value='07/01/2026']"
      end

      2.times do
        assert_no_difference ['MileageRate.count', 'Event.count'] do
          post admin_mileage_rates_path, params: { mileage_rate: { effective_on: '02/30/2026', dollars_per_mile: '0.725' } }
        end
        assert_response :unprocessable_content
        assert_select '#mileage-rates [role=alert]', text: /Effective from/
        assert_select "form[action='#{admin_mileage_rates_path}'] input[name='mileage_rate[effective_on]'][value='02/30/2026']"
        assert_select "form[action='#{admin_mileage_rates_path}'] input[name='mileage_rate[dollars_per_mile]'][value='0.725']"
      end

      assert_difference ['MileageRate.count', 'Event.count'] do
        post admin_mileage_rates_path, params: { mileage_rate: { effective_on: '07/01/2026', dollars_per_mile: '0.725' } }
      end
      assert_redirected_to admin_policies_path(anchor: 'mileage-rates')
      rate = MileageRate.find_by!(effective_on: Date.new(2026, 7, 1))
      assert_equal BigDecimal('0.725'), rate.dollars_per_mile
      event = Event.find_by!(auditable: rate, action: 'mileage_rate_created')
      assert_equal @admin.id, event.user_id
      assert_equal '2026-07-01', event.metadata.fetch('effective_on')
      assert_equal [nil, '2026-07-01'], event.field_change_pairs.fetch('effective_on')
      assert_equal [nil, '0.725'], event.field_change_pairs.fetch('dollars_per_mile')

      follow_redirect!
      assert_select '#mileage-rates summary', text: 'Recent mileage rate changes'
      assert_select '#mileage-rates li', text: %r{Effective from 07/01/2026 · \$0\.725 per mile.*#{Regexp.escape(@admin.full_name)}}
    end

    test 'rate updates audit each actual change and stale forms show saved values without overwriting them' do
      rate = MileageRate.create!(effective_on: '07/01/2026', dollars_per_mile: '0.725')
      original_version = rate.lock_version
      patch admin_mileage_rate_path(rate), params: { mileage_rate: { effective_on: '08/01/2026', dollars_per_mile: '0.700', lock_version: original_version } }
      assert_redirected_to admin_policies_path(anchor: 'mileage-rates')
      assert_equal Date.new(2026, 8, 1), rate.reload.effective_on
      assert_equal BigDecimal('0.700'), rate.dollars_per_mile
      saved_version = rate.lock_version

      assert_no_difference 'Event.count' do
        patch admin_mileage_rate_path(rate), params: { mileage_rate: { effective_on: '09/01/2026', dollars_per_mile: '0.900', lock_version: original_version } }
      end
      assert_response :unprocessable_content
      assert_select '#mileage-rates [role=alert]', text: /saved value is shown/
      assert_select "form[action='#{admin_mileage_rate_path(rate)}'] input[name='mileage_rate[dollars_per_mile]'][value='0.7']"
      assert_select "form[action='#{admin_mileage_rate_path(rate)}'] input[name='mileage_rate[lock_version]'][value='#{saved_version}']"
      assert_equal BigDecimal('0.700'), rate.reload.dollars_per_mile
      assert_select "form[action='#{admin_mileage_rate_path(rate)}'] input[name='mileage_rate[effective_on]'][value='08/01/2026']"

      patch admin_mileage_rate_path(rate), params: { mileage_rate: { effective_on: '09/01/2026', dollars_per_mile: '0.750', lock_version: saved_version } }
      assert_redirected_to admin_policies_path(anchor: 'mileage-rates')
      assert_equal BigDecimal('0.750'), rate.reload.dollars_per_mile
      events = Event.where(auditable: rate, action: 'mileage_rate_updated').order(:id).to_a
      assert_equal 2, events.size
      assert_equal [@admin.id], events.map(&:user_id).uniq
      assert_equal([['0.725', '0.7'], ['0.7', '0.75']], events.map { |event| event.field_change_pairs.fetch('dollars_per_mile') })
      assert_equal([%w[2026-07-01 2026-08-01], %w[2026-08-01 2026-09-01]], events.map { |event| event.field_change_pairs.fetch('effective_on') })
    end

    test 'duplicate dates are refused and a date-only correction retains its rate history' do
      rate = MileageRate.create!(effective_on: '07/01/2026', dollars_per_mile: '0.725')
      other = MileageRate.create!(effective_on: '08/01/2026', dollars_per_mile: '0.760')
      assert_no_difference ['MileageRate.count', 'Event.count'] do
        post admin_mileage_rates_path, params: { mileage_rate: { effective_on: '07/01/2026', dollars_per_mile: '0.700' } }
        assert_response :unprocessable_content
        patch admin_mileage_rate_path(rate), params: { mileage_rate: { effective_on: '08/01/2026', lock_version: rate.lock_version } }
        assert_response :unprocessable_content
      end
      assert_select "form[action='#{admin_mileage_rate_path(rate)}'] input[name='mileage_rate[effective_on]'][value='08/01/2026']"
      assert_equal Date.new(2026, 7, 1), rate.reload.effective_on
      assert_equal BigDecimal('0.760'), other.reload.dollars_per_mile

      patch admin_mileage_rate_path(rate), params: { mileage_rate: { effective_on: '06/01/2026', lock_version: rate.lock_version } }
      assert_redirected_to admin_policies_path(anchor: 'mileage-rates')
      event = Event.find_by!(auditable: rate, action: 'mileage_rate_updated')
      assert_equal %w[2026-07-01 2026-06-01], event.field_change_pairs.fetch('effective_on')
      assert_not event.field_changes.key?('dollars_per_mile')
      follow_redirect!
      assert_select '#mileage-rates li', text: %r{Effective from 07/01/2026 → 06/01/2026 · \$0\.725 per mile}
    end

    test 'non administrators cannot create or change mileage rates' do
      rate = MileageRate.create!(effective_on: '07/01/2026', dollars_per_mile: '0.725')
      sign_in_as(create(:constituent), bypass_mfa_enrollment: true)

      assert_no_difference ['MileageRate.count', 'Event.count'] do
        post admin_mileage_rates_path, params: { mileage_rate: { effective_on: '08/01/2026', dollars_per_mile: '0.800' } }
        assert_redirected_to root_path
        patch admin_mileage_rate_path(rate), params: { mileage_rate: { dollars_per_mile: '0.800', lock_version: rate.lock_version } }
        assert_redirected_to root_path
      end
      assert_equal BigDecimal('0.725'), rate.reload.dollars_per_mile
    end

    test 'an audit failure rolls back the mileage rate write' do
      AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(Event.new))
      assert_no_difference ['MileageRate.count', 'Event.count'] do
        post admin_mileage_rates_path, params: { mileage_rate: { effective_on: '07/01/2026', dollars_per_mile: '0.725' } }
        assert_response :unprocessable_content
      end
    end
  end
end
