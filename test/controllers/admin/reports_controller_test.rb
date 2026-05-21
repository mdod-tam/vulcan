# frozen_string_literal: true

require 'test_helper'

module Admin
  class ReportsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
    end

    test 'index includes operational vs MFR distinction copy' do
      get admin_reports_path
      assert_response :success
      assert_match(/created.*fiscal year/i, response.body)
      assert_match(/status transitions/i, response.body)
      assert_match(/not MFR/i, response.body)
    end

    test 'index includes text-only service status breakdowns' do
      travel_to Time.zone.local(2026, 5, 1, 12, 0, 0) do
        create(:training_session, status: :requested, created_at: Time.zone.local(2025, 8, 1, 12, 0, 0))
        create(:training_session, :completed, created_at: Time.zone.local(2024, 8, 1, 12, 0, 0))
        create(:evaluation, status: :scheduled, created_at: Time.zone.local(2025, 8, 1, 12, 0, 0))
        create(:evaluation, status: :no_show, created_at: Time.zone.local(2024, 8, 1, 12, 0, 0))

        training_request = create_reviewed_application(user: create(:constituent))
        training_request.update!(training_requested_at: 1.hour.ago)
        evaluation_request = create_reviewed_application(user: create(:constituent))
        evaluation_request.update!(evaluation_requested_at: 1.hour.ago)

        get admin_reports_path
        assert_response :success

        assert_select '#service-status-breakdown-heading', text: 'Service Status Breakdown'
        assert_select 'caption', text: 'Training Sessions by Status', visible: false
        assert_select 'caption', text: 'Evaluation Sessions by Status', visible: false
        assert_definition_value 'Training requests awaiting session', '1'
        assert_definition_value 'Evaluation requests awaiting session', '1'

        training_table = css_select('caption').find { |caption| caption.text.strip == 'Training Sessions by Status' }.ancestors('table').first
        evaluation_table = css_select('caption').find { |caption| caption.text.strip == 'Evaluation Sessions by Status' }.ancestors('table').first

        assert_status_row training_table, 'Requested', current_fy: 1, previous_fy: 0
        assert_status_row training_table, 'Completed', current_fy: 0, previous_fy: 1
        assert_status_row evaluation_table, 'Scheduled', current_fy: 1, previous_fy: 0
        assert_status_row evaluation_table, 'No show', current_fy: 0, previous_fy: 1
      end
    end

    test 'voucher statistics count vouchers by issued_at' do
      travel_to Time.zone.local(2026, 5, 1, 12, 0, 0) do
        application = create_reviewed_application(user: create(:constituent))
        create(:voucher,
               application: application,
               created_at: Time.zone.local(2024, 8, 1, 12, 0, 0),
               issued_at: Time.zone.local(2025, 8, 1, 12, 0, 0))

        get admin_reports_path
        assert_response :success

        current_card = css_select('#current-fy-vouchers-heading').first.ancestors('div').first
        previous_card = css_select('#previous-fy-vouchers-heading').first.ancestors('div').first

        assert_card_definition_value current_card, 'Vouchers Issued:', '1'
        assert_card_definition_value previous_card, 'Vouchers Issued:', '0'
      end
    end

    test 'MFR section table cell values match chart JSON payload' do
      travel_to Date.new(2026, 8, 1) do
        admin = create(:admin)
        fy_time = Date.new(2025, 8, 1)

        app = create(:application, :draft, created_at: fy_time)
        app.transition_status!(:approved, actor: admin, metadata: { trigger: 'test' })
        change = ApplicationStatusChange.lifecycle.find_by(application: app, to_status: 'approved')
        change.update!(changed_at: fy_time + 1.day)

        get admin_reports_path
        assert_response :success

        result = Applications::ReportingService.new.generate_mfr_reports_data
        assert result.success?

        most_recent = result.data[:most_recent_fy]
        chart = result.data[:mfr_chart_data][:current]

        tables = css_select('#mfr-data-heading').first.ancestors('section').first.css('table')
        first_card_table = tables.first

        most_recent[:chart_data].each do |label, value|
          row = first_card_table.css('tbody tr').find { |tr| tr.css('td').first.text.strip == label }
          assert_not_nil row, "expected table row for #{label}"
          assert_equal value, row.css('td').last.text.strip.to_i
        end

        chart.each do |label, expected|
          assert_equal expected, most_recent[:chart_data][label]
        end

        mfr_section = css_select('#mfr-data-heading').first.ancestors('section').first
        chart_element = mfr_section.at_css('[data-reports-chart-title-value="MFR throughput comparison"]')
        assert_not_nil chart_element
        assert_equal most_recent[:fy_label], chart_element['data-reports-chart-current-dataset-label-value']
        assert_equal result.data[:preceding_fy][:fy_label],
                     chart_element['data-reports-chart-previous-dataset-label-value']
        parsed_chart = JSON.parse(chart_element['data-reports-chart-current-data-value'])
        assert_equal chart, parsed_chart
      end
    end

    private

    def assert_status_row(table, label, current_fy:, previous_fy:)
      row = table.css('tbody tr').find { |tr| tr.css('th').first.text.strip == label }
      assert_not_nil row, "expected service status row for #{label}"
      assert_equal current_fy.to_s, row.css('td')[0].text.strip
      assert_equal previous_fy.to_s, row.css('td')[1].text.strip
    end

    def assert_definition_value(label, value)
      term = css_select('dt').find { |dt| dt.text.strip == label }
      assert_not_nil term, "expected definition term for #{label}"
      assert_equal value, term.parent.css('dd').first.text.strip
    end

    def assert_card_definition_value(card, label, value)
      term = card.css('dt').find { |dt| dt.text.strip == label }
      assert_not_nil term, "expected definition term for #{label}"
      assert_equal value, term.parent.css('dd').first.text.strip
    end

    def create_reviewed_application(user:)
      application = create(:application, skip_proofs: true, user: user, status: :in_progress)
      application.income_proof.attach(
        io: StringIO.new('income proof content'),
        filename: 'income.pdf',
        content_type: 'application/pdf'
      )
      application.residency_proof.attach(
        io: StringIO.new('residency proof content'),
        filename: 'residency.pdf',
        content_type: 'application/pdf'
      )
      application.update_columns(
        status: Application.statuses[:approved],
        income_proof_status: Application.income_proof_statuses[:approved],
        residency_proof_status: Application.residency_proof_statuses[:approved],
        medical_certification_status: Application.medical_certification_statuses[:approved],
        updated_at: Time.current
      )
      application.reload
    end
  end
end
