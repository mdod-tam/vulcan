# frozen_string_literal: true

# Shared by the training and evaluation assignment writers. Users lock before the application, in ascending id
# order, so a concurrent capability change and an assignment can never wait on each other.
module PractitionerAssignment
  extend ActiveSupport::Concern

  private

  # Locks the assignee, the acting administrator and any current assignees, then returns the assignee and actor
  # rows plus the locked ids. A missing or unsaved participant comes back nil and fails the caller's eligibility check.
  def lock_assignment_participants(assignee, actor, current_assignee_ids = [])
    ids = User.where(id: [assignee&.id, actor&.id, *current_assignee_ids].compact.uniq).pluck(:id)
    locked = ids.empty? ? {} : User.lock_for_merge_integrity!(ids)
    [locked[assignee&.id], locked[actor&.id], locked.keys]
  end

  def assignment_actor_eligible?(actor)
    actor&.admin? && actor.public_login_active?
  end
end
