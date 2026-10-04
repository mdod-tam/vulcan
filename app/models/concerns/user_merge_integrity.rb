# frozen_string_literal: true

# Shares lock order and post-merge immutability between same-person merges and online writers.
# See .cursor/plans/contact_foundation_pr4b_admin_merge.plan.md sections 2 and 4.
#
# Callers that lock multiple +User+ rows during a concurrent merge must use +lock_for_merge_integrity!+.
# Shared order avoids deadlocks from conflicting User lock sequences.
# Do not replace this method with separate `SELECT ... FOR UPDATE ORDER BY id` queries.
module UserMergeIntegrity
  extend ActiveSupport::Concern

  included do
    # A retired duplicate is historical evidence.
    # Ordinary edits must not restore public contact or change other attributes. Deletion must not remove it.
    # The live database read blocks stale instances but takes no lock.
    # See +currently_merged_in_database?+ for the race limitation.
    #
    # For TOCTOU protection, merge-sensitive writers must first lock the affected User
    # through +lock_for_merge_integrity!+.
    # These writers include portal submission/autosave, contact edits, sign-in/reset, and secure-request issuance.
    # They must then requalify and mutate the locked row, as Users::DuplicateMergeService does.
    validate :merged_record_immutable, on: :update
    before_destroy :reject_merged_record_destroy
  end

  class_methods do
    # Locks users in ascending id order and returns fresh records keyed by id.
    # Requires an open transaction. The locks last until the transaction ends.
    # Accepts User instances, ids, or a mix. Duplicate ids require one lock.
    def lock_for_merge_integrity!(*users_or_ids)
      ids = users_or_ids.flatten.compact.map { |value| value.is_a?(User) ? value.id : value.to_i }.uniq
      raise ArgumentError, 'lock_for_merge_integrity! requires at least one user' if ids.empty?
      raise ArgumentError, 'lock_for_merge_integrity! must run inside an open transaction' unless User.connection.transaction_open?

      # Use the base User class to avoid an STI subclass's `type` scope.
      # For example, Users::Constituent.lock_for_merge_integrity! must also lock and return users of other STI types.
      locked = User.unscoped.where(id: ids).order(:id).lock('FOR UPDATE').to_a
      raise ActiveRecord::RecordNotFound, "Could not lock all users for merge integrity: #{ids}" if locked.size != ids.size

      locked.index_by(&:id)
    end
  end

  private

  def merged_record_immutable
    errors.add(:base, 'A merged record cannot be modified') if currently_merged_in_database?
  end

  def reject_merged_record_destroy
    return unless currently_merged_in_database?

    errors.add(:base, 'A merged record cannot be deleted')
    throw :abort
  end

  # The *unlocked* read uses the live database value instead of this instance's stale attribute or dirty-tracking delta.
  # This blocks an instance loaded before retirement that still holds a blank merged_into_user_id.
  #
  # The read does not close the TOCTOU window: a writer can see a blank value while a merge remains uncommitted.
  # Its UPDATE can then wait for the merge's lock and apply after the merge commits.
  # Merge-sensitive writers must call `lock_for_merge_integrity!` before this read. See the class comment.
  #
  # `FOR UPDATE` here would add a lock query to ordinary User updates and deletion, with the cost hidden in callbacks.
  # It could also cause deadlocks with writers that already hold another table's lock.
  # `update_all` and raw SQL would still bypass the callbacks.
  # Explicit caller locks provide concurrency control. This read remains a best-effort backstop for other writers.
  def currently_merged_in_database?
    return false if new_record?

    # `.unscoped` removes default_scopes but retains an STI subclass's implicit `type` predicate.
    # `Users::Constituent.unscoped` still emits `WHERE type = 'Users::Constituent'`.
    # After an admin role conversion, self.class could miss the row for a stale instance and falsely report "not merged".
    # The base User class reads the row regardless of its current STI type.
    User.unscoped.where(id: id).pick(:merged_into_user_id).present?
  end
end
