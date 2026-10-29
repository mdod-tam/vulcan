# frozen_string_literal: true

require 'test_helper'

# Every rejection reason that states the applicant's address uses this one line.
class UserMailingAddressLineTest < ActiveSupport::TestCase
  test 'joins the street lines, then the city, state, and zip code' do
    user = build(:constituent, physical_address_1: '123 Main St', physical_address_2: 'Apt 4',
                               city: 'Baltimore', state: 'MD', zip_code: '21201')

    assert_equal '123 Main St Apt 4 Baltimore, MD 21201', user.mailing_address_line
  end

  test 'leaves out a missing second street line, city, state, or zip code without stray punctuation' do
    base = { physical_address_1: '123 Main St', physical_address_2: nil, city: 'Baltimore', state: 'MD', zip_code: '21201' }

    {
      {} => '123 Main St Baltimore, MD 21201',
      { city: nil } => '123 Main St MD 21201',
      { state: nil } => '123 Main St Baltimore, 21201',
      { zip_code: nil } => '123 Main St Baltimore, MD',
      { city: nil, state: nil, zip_code: nil } => '123 Main St'
    }.each do |overrides, expected|
      assert_equal expected, build(:constituent, **base, **overrides).mailing_address_line, overrides.inspect
    end
  end

  test 'is empty when the user has no address' do
    user = build(:constituent, physical_address_1: nil, physical_address_2: nil, city: nil, state: nil, zip_code: nil)

    assert_equal '', user.mailing_address_line
  end
end
