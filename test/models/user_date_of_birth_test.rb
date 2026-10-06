# frozen_string_literal: true

require 'test_helper'

# Writing, reading, and encrypted lookup must agree on one interpretation of a date of birth.
class UserDateOfBirthTest < ActiveSupport::TestCase
  test 'every accepted spelling stores the same date' do
    %w[9/10/1980 09/10/1980 09-10-1980 09.10.1980 09101980 1980-09-10].each do |spelling|
      user = Users::Constituent.new(date_of_birth: spelling)

      assert_equal Date.new(1980, 9, 10), user.date_of_birth, spelling
      assert_nil user.rejected_date_of_birth_input
    end
  end

  # The old reader fell back to Date.parse and answered 2009-09-26 for this.
  test 'rejected input is never stored or read back as a different date' do
    user = Users::Constituent.new(date_of_birth: '9/9/26')

    assert_nil user.read_attribute(:date_of_birth)
    assert_nil user.date_of_birth
    assert_equal '9/9/26', user.rejected_date_of_birth_input
    assert_not user.valid?
    assert_includes user.errors[:date_of_birth], 'is not a valid date. Enter it as MM/DD/YYYY'
  end

  test 'a later valid assignment clears the rejected input' do
    user = Users::Constituent.new(date_of_birth: 'not a date')
    user.date_of_birth = '09/10/1980'

    assert_nil user.rejected_date_of_birth_input
    assert_equal Date.new(1980, 9, 10), user.date_of_birth
  end

  test 'blank is not reported as an invalid date' do
    user = Users::Constituent.new(date_of_birth: '')

    assert_nil user.rejected_date_of_birth_input
    user.valid?
    assert_not_includes user.errors[:date_of_birth], 'is not a valid date. Enter it as MM/DD/YYYY'
  end

  test 'the error message follows the locale and keeps month first' do
    user = Users::Constituent.new(date_of_birth: '9/9/26')

    I18n.with_locale(:es) do
      user.valid?
      assert_includes user.errors.full_messages, 'Fecha de nacimiento no es una fecha válida. Ingrésela como MM/DD/AAAA'
    end
  end

  test 'a stored date round-trips through the encrypted column' do
    user = create(:constituent, date_of_birth: '09/10/1980')

    assert_equal Date.new(1980, 9, 10), Users::Constituent.find(user.id).date_of_birth
  end

  # Deterministic encryption matches only the identical stored text, so every spelling has to
  # reach the same ISO value before the query.
  test 'duplicate lookup finds the stored record from any accepted spelling' do
    user = create(:constituent, first_name: 'Spelling', last_name: 'Lookup', date_of_birth: Date.new(1980, 9, 10))

    [Date.new(1980, 9, 10), '1980-09-10', '09/10/1980', '09-10-1980', '09101980'].each do |dob|
      assert_includes Users::Constituent.find_duplicates('Spelling', 'Lookup', dob).pluck(:id), user.id, dob.inspect
    end
    assert_empty Users::Constituent.find_duplicates('Spelling', 'Lookup', '10/09/1980')
    assert_empty Users::Constituent.find_duplicates('Spelling', 'Lookup', '9/10/80')
  end
end
