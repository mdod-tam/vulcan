# frozen_string_literal: true

require 'test_helper'

module Reports
  class FiscalYearReportTest < ActiveSupport::TestCase
    test 'fiscal year labels follow the July start' do
      assert_equal 'FY27', FiscalYearReport.new(today: Date.new(2026, 9, 1)).current_fy_label
      assert_equal 'FY26', FiscalYearReport.new(today: Date.new(2026, 9, 1)).previous_fy_label
      assert_equal 'FY26', FiscalYearReport.new(today: Date.new(2026, 6, 30)).current_fy_label
    end

    test 'applications and drafts are counted in the fiscal year they were created' do
      today = Date.new(2026, 11, 1)
      before = FiscalYearReport.new(today: today)
      baseline = { current: before.current_fy_applications, drafts: before.current_fy_draft_applications,
                   previous: before.previous_fy_applications }
      create(:application, :in_progress, created_at: Time.zone.local(2026, 8, 1, 12))
      create(:application, :draft, created_at: Time.zone.local(2026, 9, 1, 12))
      create(:application, :in_progress, created_at: Time.zone.local(2025, 8, 1, 12))
      report = FiscalYearReport.new(today: today)

      assert_equal baseline[:current] + 2, report.current_fy_applications
      assert_equal baseline[:drafts] + 1, report.current_fy_draft_applications
      assert_equal baseline[:previous] + 1, report.previous_fy_applications
      assert_equal report.current_fy_applications, report.applications_chart_data[:current]['Applications Created']
    end

    test 'status counts list every status' do
      counts = FiscalYearReport.new(today: Date.new(2026, 11, 1)).current_fy_training_status_counts

      assert_equal TrainingSession.statuses.keys.sort, counts.keys.sort
      assert counts.values.all?(Integer)
    end

    test 'referral sources count each applicant once and name a missing source' do
      today = Date.new(2026, 11, 15)
      before = FiscalYearReport.new(today: today).referral_month_data
      applicant = create(:constituent, referral_source: 'Library Test Source')
      create(:application, :in_progress, user: applicant, created_at: Time.zone.local(2026, 11, 2, 12))
      create(:application, :in_progress, user: applicant, created_at: Time.zone.local(2026, 11, 3, 12))
      create(:application, :in_progress, user: create(:constituent, referral_source: ''), created_at: Time.zone.local(2026, 11, 4, 12))
      after = FiscalYearReport.new(today: today).referral_month_data

      assert_equal 1, after['Library Test Source']
      assert_equal before.fetch('Not Specified', 0) + 1, after['Not Specified']
      assert_equal 'November 2026', FiscalYearReport.new(today: today).referral_month_label
    end

    test 'chart data is keyed by label and defaults missing counts to zero' do
      report = FiscalYearReport.new(today: Date.new(2026, 11, 1))

      assert_equal %w[Hearing Vision Speech Mobility Cognition], report.disability_chart_data(:current).keys
      assert report.disability_chart_data(:previous).values.all?(Integer)
      assert_equal %w[Issued Active Expired], report.voucher_status_chart_data(:current).keys
      assert report.voucher_status_chart_data(:previous).values.all?(Integer)
    end

    test 'the recent vendor share is a percentage and is zero without vendors' do
      report = FiscalYearReport.new(today: Date.new(2026, 11, 1))
      report.stubs(:active_vendors).returns(0)
      assert_in_delta 0.0, report.recent_active_vendor_percentage

      report.stubs(:active_vendors).returns(4)
      report.stubs(:recent_active_vendors).returns(1)
      assert_in_delta 25.0, report.recent_active_vendor_percentage
    end

    test 'a figure is computed once however often the view reads it' do
      report = FiscalYearReport.new(today: Date.new(2026, 11, 1))
      report.current_fy_applications

      queries = 0
      counter = ->(*, payload) { queries += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { 3.times { report.current_fy_applications } }

      assert_equal 0, queries
    end
  end
end
