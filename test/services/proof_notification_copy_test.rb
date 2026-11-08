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

  test 'Spanish proof labels and statuses use the requested locale independently of the ambient locale' do
    I18n.with_locale(:en) do
      assert_equal 'Comprobante de identidad', ProofNotificationCopy.proof_label('ID_PROOF', locale: :es)
      assert_equal 'Comprobante de ingresos', ProofNotificationCopy.proof_label('Income Proof', locale: :es)
      assert_equal 'Comprobante', ProofNotificationCopy.proof_label(nil, locale: :es)
      assert_equal 'Comprobante de residencia aprobado', ProofNotificationCopy.approved_text('residency', locale: :es)
      assert_equal 'Comprobante de identidad adjuntado', ProofNotificationCopy.attached_text('id', locale: :es)
      assert_equal 'Comprobante de ingresos no proporcionado', ProofNotificationCopy.not_provided_text('income', locale: :es)
      assert_equal 'Comprobante de identidad solicitado', ProofNotificationCopy.requested_text('id', locale: :es)
      assert_equal 'Comprobante de ingresos rechazado - Documento ilegible',
                   ProofNotificationCopy.rejected_text('income', 'Documento ilegible', locale: :es)
      assert_equal 'Comprobante de ingresos rechazado', ProofNotificationCopy.rejected_text('income', nil, locale: :es)
    end
  end

  test 'proof copy follows the ambient locale when the caller supplies none' do
    I18n.with_locale(:es) do
      assert_equal 'Comprobante de residencia solicitado', ProofNotificationCopy.requested_text('residency')
      assert_equal 'ID proof requested', ProofNotificationCopy.requested_text('id', locale: :en)
    end
  end
end
