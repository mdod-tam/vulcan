# frozen_string_literal: true

module Icanconnect
  module RetainedAttachment
    extend ActiveSupport::Concern

    def delete
      with_retained_evidence_lock { super }
    end

    def destroy
      with_retained_evidence_lock { super }
    end

    private

    def with_retained_evidence_lock
      if record.is_a?(Application) && name == 'previous_income_proofs' && self.class.exists?(id: id)
        raise ActiveRecord::RecordNotDestroyed, 'Previous income evidence must be retained with its proof reviews'
      end

      financial = %w[financial_document superseded_financial_documents].include?(name)
      return yield unless financial && record.respond_to?(:icc_financial_evidence_locked?) && record.persisted?
      return yield if record.icc_correction_write || !self.class.exists?(id: id)

      record.class.transaction do
        Icanconnect::FinancialContext.lock!([record])
        record.lock!
        raise ActiveRecord::RecordNotDestroyed, 'Filed financial evidence requires an audited correction' if record.icc_financial_evidence_locked?

        yield
      end
    end
  end
end
