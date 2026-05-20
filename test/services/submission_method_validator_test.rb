# frozen_string_literal: true

require 'test_helper'

class SubmissionMethodValidatorTest < ActiveSupport::TestCase
  test 'validates known submission methods' do
    valid_methods = %i[paper web email secure_form unknown]

    valid_methods.each do |method|
      result = SubmissionMethodValidator.validate(method)
      assert_equal method, result
      assert_kind_of Symbol, result
    end
  end

  test 'handles string versions of valid methods' do
    assert_equal :paper, SubmissionMethodValidator.validate('paper')
    assert_equal :web, SubmissionMethodValidator.validate('web')
    assert_equal :secure_form, SubmissionMethodValidator.validate('secure_form')
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

  # secure_request_form is the audit source for provider-info submissions.
  # The plan requires it NOT to pass through SubmissionMethodValidator, which is
  # proof-attachment-specific today. Verifying it coerces to :unknown ensures
  # the two audit paths never accidentally merge.
  test 'does not accept secure_request_form as a valid submission method' do
    assert_equal :unknown, SubmissionMethodValidator.validate(:secure_request_form)
    assert_equal :unknown, SubmissionMethodValidator.validate('secure_request_form')
  end
end
