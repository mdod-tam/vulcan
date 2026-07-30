# frozen_string_literal: true

# Shared row-lock ordering and post-merge immutability for the same-person merge boundary
# and the online writers that must serialize with it
# (see .cursor/plans/contact_foundation_pr4b_admin_merge.plan.md sections 2 and 4).
#
# Every caller that needs to lock more than one +User+ row against a concurrent merge must
# go through +lock_for_merge_integrity!+ instead of hand-rolling
# `SELECT ... FOR UPDATE ORDER BY id`, so the lock order is identical everywhere and two
# callers can never deadlock against each other.
module UserMergeIntegrity
  extend ActiveSupport::Concern

  included do
    # A retired duplicate is immutable historical evidence: once merged, it cannot regain
    # public contact or any other attribute through ordinary edits, regardless of caller.
    # This is a best-effort backstop against a stale in-memory instance, not a substitute
    # for real concurrency control: it reads the live database row rather than this
    # instance's own dirty tracking, but deliberately does NOT take a row lock here (see
    # +currently_merged_in_database?+ for why). The actual merge-sensitive writers (portal
    # submission/autosave, contact edits, sign-in/reset, secure-request issuance) must lock
    # the affected User row themselves via +lock_for_merge_integrity!+ before requalifying
    # and mutating, exactly like Users::DuplicateMergeService already does -- that is where
    # real TOCTOU protection belongs, not in a validation every ordinary User save pays for.
    validate :merged_record_immutable, on: :update
    before_destroy :reject_merged_record_destroy
  end

  class_methods do
    # Locks the given users, in ascending id order, inside the current transaction and
    # returns them reloaded from their locked rows, keyed by id. Must run inside an open
    # transaction; the lock is released when that transaction ends. Accepts User instances,
    # ids, or a mix; duplicate ids collapse to a single lock.
    def lock_for_merge_integrity!(*users_or_ids)
      ids = users_or_ids.flatten.compact.map { |value| value.is_a?(User) ? value.id : value.to_i }.uniq
      raise ArgumentError, 'lock_for_merge_integrity! requires at least one user' if ids.empty?
      raise ArgumentError, 'lock_for_merge_integrity! must run inside an open transaction' unless User.connection.transaction_open?

      # Explicitly through the base User class, unscoped: this concern is included in every
      # STI subclass, and calling the inherited class method through one (e.g.
      # Users::Constituent.lock_for_merge_integrity!) would otherwise apply that subclass's
      # `type` scope and silently fail to lock/return a row of a different STI type.
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

  # The live database value via an *unlocked* read -- not this instance's own (possibly
  # stale) in-memory attribute or dirty-tracking delta, but deliberately not `FOR UPDATE`
  # either. An unlocked read closes the stale-instance bypass (an instance loaded before
  # retirement, never reloaded, would otherwise see its own blank in-memory attribute
  # forever) while staying a cheap, ordinary SELECT that every User save/destroy can afford.
  #
  # It does NOT close the narrower TOCTOU window where a writer reads this as blank while a
  # merge is still uncommitted, then physically waits behind the merge's row lock on its own
  # UPDATE, and lands right after the merge commits. Closing that window requires the row to
  # already be locked *before* this check runs, and only a caller that itself calls
  # `lock_for_merge_integrity!` first can guarantee that -- adding `FOR UPDATE` here instead
  # would force every ordinary User update/destroy in the app to pay for an extra query and
  # lock, quietly pull unrelated services into this lock order (risking a *new* deadlock
  # against any service that already held a different table's lock first), hide that cost
  # inside a validation callback, and still be bypassable via any `update_all`/raw-SQL path.
  # That trade is worse than the race it would close. Merge-sensitive writers must lock the
  # affected User explicitly (see the class comment); this check is the best-effort backstop
  # for everything else.
  def currently_merged_in_database?
    return false if new_record?

    # Through the base User class, not self.class: `.unscoped` only removes default_scopes,
    # not the implicit STI `type` predicate that an STI subclass always adds to its own
    # relations (confirmed via generated SQL: `Users::Constituent.unscoped` still emits
    # `WHERE type = 'Users::Constituent'`). A stale instance loaded before an admin role
    # conversion would otherwise query for a row that, by its now-outdated `type`, no longer
    # exists -- finding nothing and silently reporting "not merged" instead of checking the
    # live row at all.
    User.unscoped.where(id: id).pick(:merged_into_user_id).present?
  end
end
