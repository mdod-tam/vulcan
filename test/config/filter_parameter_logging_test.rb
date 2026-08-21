# frozen_string_literal: true

require 'test_helper'

class FilterParameterLoggingTest < ActiveSupport::TestCase
  test 'filters contact and password parameters from logs' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      'contact' => '410-555-0198',
      'password' => 'password123',
      'controller' => 'sessions',
      'action' => 'create'
    )

    assert_equal '[FILTERED]', filtered['contact']
    assert_equal '[FILTERED]', filtered['password']
    assert_equal 'sessions', filtered['controller']
    assert_equal 'create', filtered['action']
  end

  # Paper identity review posts the applicant's identifying facts and receives a short-lived
  # decision token, which the form then submits back. POST keeps those out of the URL; this keeps
  # them out of the log. The names matter here specifically because they travel alongside a date of
  # birth and an address, and that combination is what identifies a person.
  test 'filters paper identity review facts and the decision token from logs' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      'constituent' => {
        'first_name' => 'Jane', 'last_name' => 'Doe', 'date_of_birth' => '1990-04-02',
        'email' => 'jane@example.com', 'phone' => '555-000-0000',
        'physical_address_1' => '1 Main St', 'city' => 'Baltimore', 'zip_code' => '21201'
      },
      'identity_decision' => "v1:#{Time.current.to_i}:#{'a' * 64}",
      'controller' => 'admin/paper_applications',
      'action' => 'identity_review'
    )

    %w[first_name last_name date_of_birth email phone physical_address_1 city zip_code].each do |field|
      assert_equal '[FILTERED]', filtered['constituent'][field], "#{field} must not reach the log"
    end
    assert_equal '[FILTERED]', filtered['identity_decision'],
                 'the decision token authorizes a creation and must not outlive its request in a log'
    assert_equal 'identity_review', filtered['action']
  end

  # Filtering the request parameters is only half of it. The identity-matching query puts the same
  # names back on their way to the database, and `filter_parameters` matches on a bind's attribute
  # name -- so a positional bind, which Active Record logs as `[nil, "smith"]`, has no name to match
  # and lands in the query log in the clear. The date of birth was filtered the whole time only
  # because a hash condition carries its column name.
  #
  # Asserts the values are absent rather than that the binds are named: the requirement is that the
  # name does not reach the log, not that any particular construction is used to achieve it.
  test 'the duplicate-matching query does not write names to the query log' do
    log = capture_active_record_log do
      Users::Constituent.find_duplicates('SqlBindProbeFirst', 'SqlBindProbeLast', Date.new(1990, 4, 2)).to_a
    end

    assert_no_match(/sqlbindprobefirst/i, log, 'the first name reached the query log')
    assert_no_match(/sqlbindprobelast/i, log, 'the last name reached the query log')
    assert_match(/\["first_name", "\[FILTERED\]"\]/, log, 'the first name bind should be named and redacted')
    assert_match(/\["last_name", "\[FILTERED\]"\]/, log, 'the last name bind should be named and redacted')
  end

  # Redaction is worthless if it changed what the query matches, and this query decides whether two
  # people are the same person.
  test 'the duplicate-matching query still matches case-insensitively on name and date of birth' do
    existing = create(:constituent, first_name: 'Casing', last_name: 'Probe',
                                    date_of_birth: Date.new(1990, 4, 2))

    assert_includes Users::Constituent.find_duplicates('cAsInG', 'pRoBe', Date.new(1990, 4, 2)).map(&:id),
                    existing.id
    assert_not_includes Users::Constituent.find_duplicates('Casing', 'Probe', Date.new(1991, 4, 2)).map(&:id),
                        existing.id
  end

  private

  def capture_active_record_log
    io = StringIO.new
    original = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(io)
    ActiveRecord::Base.logger.level = :debug
    yield
    io.string
  ensure
    ActiveRecord::Base.logger = original
  end
end
