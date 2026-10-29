# frozen_string_literal: true

require 'test_helper'

# RejectionReason is the one owner of what a stored reason says about an application and of which reasons
# the rejection forms offer. The services, mailers, and forms that use it have their own tests.
class RejectionReasonTest < ActiveSupport::TestCase
  setup do
    applicant = create(:constituent, physical_address_1: '123 Main St', physical_address_2: 'Apt 4',
                                     city: 'Baltimore', state: 'MD', zip_code: '21201')
    @application = create(:application, user: applicant)
    @address = '123 Main St Apt 4 Baltimore, MD 21201'
  end

  test 'a persisted reason states the applicant address on one line and keeps its code' do
    create(:rejection_reason, code: 'zz_state_address', proof_type: 'income', body: 'Send proof for %<address>s.')

    resolved = RejectionReason.resolve_for_persistence(code: 'zz_state_address', proof_type: 'income', fallback: nil,
                                                       application: @application)

    assert_equal({ text: "Send proof for #{@address}.", code: 'zz_state_address' }, resolved)
  end

  test 'a body states the same address for mail and previews as the persisted text does' do
    reason = create(:rejection_reason, code: 'zz_mail_address', proof_type: 'residency', body: 'Match %<address>s exactly.')

    persisted = RejectionReason.resolve_text(code: reason.code, proof_type: 'residency', fallback: nil, application: @application)

    assert_equal "Match #{@address} exactly.", reason.body_for(@application)
    assert_equal persisted, reason.body_for(@application)
  end

  test 'free text and an unknown code are stored as given, without a code' do
    free_text = RejectionReason.resolve_for_persistence(code: nil, proof_type: 'income', fallback: 'In my own words', application: @application)
    unknown = RejectionReason.resolve_for_persistence(code: 'zz_no_such_reason', proof_type: 'income', fallback: 'zz_no_such_reason',
                                                      application: @application)

    assert_equal({ text: 'In my own words', code: nil }, free_text)
    assert_equal({ text: 'zz_no_such_reason', code: nil }, unknown)
  end

  test 'a body without the address placeholder is unchanged' do
    reason = create(:rejection_reason, code: 'zz_static', proof_type: 'income', body: 'Please send a clearer copy.')

    assert_equal 'Please send a clearer copy.', reason.body_for(@application)
  end

  test 'the forms offer one reason per code, in the locale where it has one and in English otherwise' do
    create(:rejection_reason, code: 'zz_both', proof_type: 'income', locale: 'en', body: 'English both')
    create(:rejection_reason, code: 'zz_both', proof_type: 'income', locale: 'es', body: 'Spanish both')
    create(:rejection_reason, code: 'zz_english_only', proof_type: 'income', locale: 'en', body: 'English only')
    create(:rejection_reason, code: 'zz_residency', proof_type: 'residency', locale: 'en', body: 'Residency')

    spanish = RejectionReason.options_for(locale: 'es', proof_type: 'income').select { |reason| reason.code.start_with?('zz_') }
    english = RejectionReason.options_for(locale: 'en', proof_type: 'income').select { |reason| reason.code.start_with?('zz_') }

    spanish_choices = spanish.map { |reason| [reason.code, reason.locale] }
    english_choices = english.map { |reason| [reason.code, reason.locale] }
    assert_equal [%w[zz_both es], %w[zz_english_only en]], spanish_choices
    assert_equal [%w[zz_both en], %w[zz_english_only en]], english_choices
  end

  test 'the forms offer every proof type when none is named, ordered by proof type and code' do
    create(:rejection_reason, code: 'zz_b', proof_type: 'residency', body: 'B')
    create(:rejection_reason, code: 'zz_a', proof_type: 'residency', body: 'A')
    create(:rejection_reason, code: 'zz_c', proof_type: 'income', body: 'C')

    ours = RejectionReason.options_for(locale: 'en').select { |reason| reason.code.start_with?('zz_') }

    choices = ours.map { |reason| [reason.proof_type, reason.code] }
    assert_equal [%w[income zz_c], %w[residency zz_a], %w[residency zz_b]], choices
  end

  test 'the forms keep none_provided and other as their own choices' do
    assert RejectionReason.exists?(code: 'none_provided'), 'precondition: the baseline stores a none_provided reason'

    assert_empty RejectionReason.options_for(locale: 'en').map(&:code) & %w[none_provided other]
  end
end
