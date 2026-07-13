# frozen_string_literal: true

module UserMergeIntegrity
  extend ActiveSupport::Concern

  included do
    validate :merged_record_cannot_own_primary_contact, on: :update
  end

  private

  # A merged row is historical identity evidence, not a second live owner of login or
  # delivery contact. Locked mutation boundaries close concurrent stale-request races;
  # this validation also rejects ordinary later attempts to restore released contact.
  def merged_record_cannot_own_primary_contact
    errors.add(:base, 'Merged records cannot own an email address or phone number') if
      merged? && (email.present? || phone.present?)
  end
end
