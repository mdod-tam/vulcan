# frozen_string_literal: true

require 'test_helper'

class PhoneNumberTest < ActiveSupport::TestCase
  test 'normalize writes a ten digit number as ddd-ddd-dddd and drops a leading country code' do
    assert_equal '410-555-1234', PhoneNumber.normalize('(410) 555-1234')
    assert_equal '410-555-1234', PhoneNumber.normalize('4105551234')
    assert_equal '410-555-1234', PhoneNumber.normalize('+1 410 555 1234')
  end

  test 'normalize returns blank as nil and any other non-US value unchanged' do
    assert_nil PhoneNumber.normalize(nil)
    assert_nil PhoneNumber.normalize('')
    assert_equal '555-1234', PhoneNumber.normalize('555-1234')
    assert_equal '24105551234', PhoneNumber.normalize('24105551234')
  end

  test 'valid? accepts exactly ten national digits' do
    assert PhoneNumber.valid?('410-555-1234')
    assert PhoneNumber.valid?('1-410-555-1234')
    assert_not PhoneNumber.valid?('410-555-123')
    assert_not PhoneNumber.valid?(nil)
  end

  test 'synthetic? marks the placeholder numbers given to dependents without a phone' do
    assert PhoneNumber.synthetic?('000-123-4567')
    assert PhoneNumber.synthetic?('0001234567')
    assert PhoneNumber.synthetic?('1-000-123-4567')
    assert_not PhoneNumber.synthetic?('410-555-1234')
    assert_not PhoneNumber.synthetic?(nil)
    assert_not PhoneNumber.synthetic?('')
  end

  test 'real? needs a valid number that is not synthetic' do
    assert PhoneNumber.real?('410-555-1234')
    assert_not PhoneNumber.real?('000-123-4567')
    assert_not PhoneNumber.real?('555-1234')
    assert_not PhoneNumber.real?('')
    assert_not PhoneNumber.real?(nil)
  end

  test 'a user reports a real phone only for a real number' do
    assert build(:constituent, phone: '410-555-1234').real_phone?
    assert_not build(:constituent, phone: '000-123-4567').real_phone?
  end
end
