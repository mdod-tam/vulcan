# frozen_string_literal: true

require 'test_helper'

class ProofNotificationCopyTest < ActiveSupport::TestCase
  test 'proof labels normalize id capitalization and proof suffixes' do
    assert_equal 'ID proof', ProofNotificationCopy.proof_label('id')
    assert_equal 'ID proof', ProofNotificationCopy.proof_label('id proof')
    assert_equal 'ID proof', ProofNotificationCopy.proof_label('id_proof')
    assert_equal 'Income proof', ProofNotificationCopy.proof_label('Income Proof')
    assert_equal 'Proof', ProofNotificationCopy.proof_label(nil)
  end

  test 'proof status text shares normalized labels' do
    assert_equal 'ID proof rejected - Too blurry', ProofNotificationCopy.rejected_text('id_proof', 'Too blurry')
    assert_equal 'Residency proof approved', ProofNotificationCopy.approved_text('residency')
    assert_equal 'Income proof requested', ProofNotificationCopy.requested_text('income')
  end
end
