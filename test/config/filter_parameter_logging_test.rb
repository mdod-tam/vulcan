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
end
