# frozen_string_literal: true

# Owns the audience of ordinary storage downloads. W9s and print letters use their dedicated release paths.
class AttachmentAccess
  PROOF_NAMES = %w[income_proof residency_proof id_proof].freeze
  CERTIFICATION_NAMES = %w[disability_certification additional_disability_certifications].freeze

  def initialize(blob)
    @blob = blob
    @attachments = blob.attachments.includes(:record).to_a
  end

  def public?
    eligible? && @attachments.all? { |attachment| attachment.record.is_a?(ProductResource) && attachment.name == 'document' }
  end

  def allowed?(user)
    return false unless user && eligible?

    # Shared bytes must meet every attached record's rule; one permissive slot cannot expose another owner.
    @attachments.all? { |attachment| application_document_allowed?(attachment, user) }
  end

  private

  def eligible?
    @eligible = @attachments.any? && !Vendors::W9Document.protected?(@blob) if @eligible.nil?
    @eligible
  end

  def application_document_allowed?(attachment, user)
    record = attachment.record
    return false unless record.is_a?(Application)
    return user.admin? if CERTIFICATION_NAMES.include?(attachment.name)
    return false unless PROOF_NAMES.include?(attachment.name)

    user.admin? || (user.constituent? && record.accessible_by?(user))
  end
end
