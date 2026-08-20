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
end
