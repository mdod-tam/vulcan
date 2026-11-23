# frozen_string_literal: true

require 'test_helper'

module Reports
  class MfrReportTest < ActiveSupport::TestCase
    include IcanconnectTestSupport

    test 'counts distinct submitters and recipients, and every MAT device delivered in the fiscal year' do
      travel_to Time.zone.local(2026, 8, 1, 12) do
        report = MfrReport.new(nil)
        previous_year = report.counts(2025)
        current_year = report.counts(2026)
        person = create(:constituent)
        submitted = create(:application, :approved, :with_all_proofs, user: person, created_at: 2.years.ago)
        submitted.status_changes.create!(from_status: 'draft', to_status: 'in_progress',
                                         changed_at: Time.zone.local(2026, 6, 30, 23, 59))
        create(:application, :archived, user: person, submission_method: :paper, created_at: Time.zone.local(2025, 7, 1))
        create(:application, :draft, created_at: Time.zone.local(2026, 5, 1))
        create(:application, :approved, :with_all_proofs, submission_method: :paper, created_at: Time.zone.local(2026, 7, 1))

        order = create(:purchase_order, sent_at: Date.new(2026, 6, 24))
        2.times do
          create(:equipment_item, application: submitted, purchase_order: order, shipped_at: Date.new(2026, 6, 26),
                                  delivered_on: Date.new(2026, 6, 30), tracking_number: 'JUNE-DELIVERY')
        end
        create(:equipment_item, application: submitted, purchase_order: order, shipped_at: Date.new(2026, 6, 26),
                                delivered_on: Date.new(2026, 7, 1), tracking_number: 'JULY-DELIVERY')
        create(:equipment_item, application: submitted, purchase_order: order, shipped_at: Date.new(2026, 6, 26),
                                tracking_number: 'STILL-IN-TRANSIT')

        assert_equal previous_year.zip([1, 1, 2]).map(&:sum), report.counts(2025)
        assert_equal current_year.zip([1, 1, 1]).map(&:sum), report.counts(2026)
      end
    end

    test 'a recorded iCanConnect delivery does not count as MAT equipment' do
      travel_to Time.zone.local(2026, 6, 30, 12) do
        @admin = create(:admin)
        start_icanconnect!
        report = MfrReport.new(nil)
        baseline = report.counts(2025)
        icc_order_with_unit

        assert_equal baseline.last(2), report.counts(2025).last(2)
      end
    end
  end
end
