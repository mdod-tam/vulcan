# frozen_string_literal: true

require 'test_helper'

class DateInputHelperTest < ActionView::TestCase
  test 'a stored date renders as MM/DD/YYYY' do
    assert_equal '09/10/1980', date_of_birth_input_value(Users::Constituent.new(date_of_birth: '1980-09-10'))
  end

  test 'an accepted alternate spelling renders in the canonical form' do
    assert_equal '09/10/1980', date_of_birth_input_value(Users::Constituent.new(date_of_birth: '09101980'))
  end

  test 'rejected input renders as typed, not blank and not reinterpreted' do
    assert_equal '9/9/26', date_of_birth_input_value(Users::Constituent.new(date_of_birth: '9/9/26'))
  end

  test 'a submitted-params hash renders its own value' do
    assert_equal '09/10/1980', date_of_birth_input_value({ date_of_birth: '1980-09-10' }.with_indifferent_access)
    assert_equal '9/9/26', date_of_birth_input_value({ date_of_birth: '9/9/26' }.with_indifferent_access)
  end

  test 'no source renders no value' do
    assert_nil date_of_birth_input_value(nil)
  end

  test 'shared field options keep caller overrides' do
    options = date_of_birth_field_options(autocomplete: 'off', id: 'dob')

    assert_equal 'off', options[:autocomplete]
    assert_equal 'numeric', options[:inputmode]
    assert_equal 'dob', options[:id]
    assert_equal 'MM/DD/YYYY', options[:placeholder]
  end
end
