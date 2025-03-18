# frozen_string_literal: true

require 'test_helper'

class SubmissionMethodValidatorTest < ActiveSupport::TestCase
  test 'validates known submission methods' do
    valid_methods = [:paper, :web, :email, :unknown]
    
    valid_methods.each do |method|
      result = SubmissionMethodValidator.validate(method)
      assert_equal method, result
      assert_kind_of Symbol, result
    end
  end
  
  test 'handles string versions of valid methods' do
    assert_equal :paper, SubmissionMethodValidator.validate('paper')
    assert_equal :web, SubmissionMethodValidator.validate('web')
  end
  
  test 'falls back to :unknown for nil submission method' do
    result = SubmissionMethodValidator.validate(nil)
    assert_equal :unknown, result
  end
  
  test 'falls back to :unknown for empty string' do
    result = SubmissionMethodValidator.validate('')
    assert_equal :unknown, result
  end
  
  test 'falls back to :unknown for invalid symbol' do
    result = SubmissionMethodValidator.validate(:invalid_method)
    assert_equal :unknown, result
  end
  
  test 'falls back to :unknown for invalid string' do
    result = SubmissionMethodValidator.validate('not_a_valid_method')
    assert_equal :unknown, result
  end
  
  test 'handles non-string/symbol inputs gracefully' do
    result = SubmissionMethodValidator.validate(123)
    assert_equal :unknown, result
    
    result = SubmissionMethodValidator.validate(Object.new)
    assert_equal :unknown, result
  end
end
