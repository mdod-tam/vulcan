# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationsListHelperTest < ActionView::TestCase
    include ApplicationsListHelper

    test 'sort links retain filter context and reset pagination' do
      query = ActionController::Parameters.new(view: 'review', status: 'awaiting_proof', q: 'River',
                                               managing_guardian_q: 'Guardian', for_minors: 'true', page: '4',
                                               sort: 'applicant', direction: 'asc', unrelated: 'discard')

      @controller.params = query
      link = Nokogiri::HTML.fragment(view.application_sort_link('Applicant', :applicant)).at_css('a')
      values = Rack::Utils.parse_query(URI.parse(link['href']).query)

      assert_equal 'review', values['view']
      assert_equal 'awaiting_proof', values['status']
      assert_equal 'River', values['q']
      assert_equal 'Guardian', values['managing_guardian_q']
      assert_equal 'true', values['for_minors']
      assert_equal 'desc', values['direction']
      assert_not values.key?('page')
      assert_not values.key?('unrelated')
      assert_equal 'applications_list', link['data-turbo-frame']
      assert_equal 'ascending', view.application_sort_aria(:applicant)
      assert_equal 'none', view.application_sort_aria(:status)
    end

    test 'first status sort selects longest duration first' do
      @controller.params = ActionController::Parameters.new
      link = Nokogiri::HTML.fragment(view.application_sort_link('Status', :status)).at_css('a')
      values = Rack::Utils.parse_query(URI.parse(link['href']).query)

      assert_equal 'status', values['sort']
      assert_equal 'desc', values['direction']
      assert_includes link['aria-label'], 'time in status'
    end

    test 'status age uses the selected status timestamp including same-day entries' do
      travel_to Time.zone.local(2026, 11, 10, 12) do
        application = Struct.new(:current_status_entered_at).new(31.days.ago)
        assert_equal '(31 days)', application_status_age(application)

        application.current_status_entered_at = 2.hours.ago
        assert_equal '(0 days)', application_status_age(application)

        application.current_status_entered_at = nil
        assert_equal 'Date unavailable', application_status_age(application)
      end
    end

    test 'pipeline date options use approval windows without fiscal creation filters' do
      values = application_date_range_options(view: 'pipeline').map(&:last)

      assert_equal ['', 'last_30', 'last_60', 'last_90', 'last_120', 'last_12_months'], values
      assert_includes application_date_range_options(view: 'all').map(&:last), 'current_fy'
    end
  end
end
