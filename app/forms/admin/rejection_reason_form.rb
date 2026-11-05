# frozen_string_literal: true

module Admin
  # A new rejection reason typed into the admin form. Applicants read the English and Spanish text in their own
  # language, so both records are created together; the name staff type becomes the reason's code.
  class RejectionReasonForm
    include ActiveModel::Model
    include ActiveModel::Attributes

    # The names staff read on the form and in its error messages.
    LABELS = { name: 'Reason name', en_body: 'Reason text (English)', es_body: 'Reason text (Spanish)' }.freeze

    def self.human_attribute_name(attribute, options = {})
      LABELS.fetch(attribute.to_sym) { super }
    end

    attribute :proof_type, :string
    attribute :name, :string
    attribute :en_body, :string
    attribute :es_body, :string

    validates :proof_type, inclusion: { in: RejectionReason::VALID_PROOF_TYPES }
    validates :name, :en_body, :es_body, presence: true
    validate :code_is_usable

    attr_reader :en_reason

    def code
      name.to_s.parameterize(separator: '_')
    end

    def save(actor:)
      return false unless valid?

      reasons = { en_body: build_reason('en', en_body, actor), es_body: build_reason('es', es_body, actor) }
      copy_record_errors(reasons)
      return false if errors.any?

      RejectionReason.transaction { reasons.each_value(&:save!) }
      @en_reason = reasons.fetch(:en_body)
      true
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      # Another admin created the same reason between the check above and the save.
      errors.add(:name, 'is already used by a rejection reason for this proof type')
      false
    end

    private

    def build_reason(locale, body, actor)
      RejectionReason.new(code: code, proof_type: proof_type, locale: locale, body: body, updated_by: actor)
    end

    def copy_record_errors(reasons)
      reasons.each do |field, reason|
        reason.errors.each { |error| errors.add(field, error.message) } unless reason.valid?
      end
    end

    def code_is_usable
      return if name.blank? || proof_type.blank?

      if code.blank?
        errors.add(:name, 'must include letters or numbers')
      elsif RejectionReason::FORM_OWN_CODES.include?(code)
        errors.add(:name, 'is reserved; rejection forms already offer this choice')
      elsif RejectionReason.exists?(code: code, proof_type: proof_type)
        errors.add(:name, 'is already used by a rejection reason for this proof type')
      end
    end
  end
end
