# frozen_string_literal: true

module Users
  # Read-only, bounded presentation of family relationships affected by a proposed
  # merge. Associations are preloaded by the controller; this object performs no query.
  class DuplicateMergeRelationshipPreview
    MAX_APPLICATIONS_PER_DEPENDENT = 5

    RelatedRecord = Data.define(:user, :relationship_type, :applications, :application_count)
    Participant = Data.define(:user, :dependents, :guardians, :application_count, :applications_managed_by_other_count)
    DirectRelationship = Data.define(:guardian, :dependent, :relationship_type)
    DependentOutcome = Data.define(:user, :applications, :application_count, :linked_from_both)
    GuardianOutcome = Data.define(:user, :linked_from_both)

    attr_reader :participants, :direct_relationships, :dependent_outcomes, :guardian_outcomes

    def initialize(first_user, second_user, related_users_by_id:)
      @users = [first_user, second_user]
      @user_ids = @users.map(&:id)
      @related_users_by_id = related_users_by_id
      @participants = @users.map { |user| participant(user) }
      @direct_relationships = build_direct_relationships
      @dependent_outcomes = build_dependent_outcomes
      @guardian_outcomes = build_guardian_outcomes
    end

    def any?
      participants.any? { |participant| participant.dependents.any? || participant.guardians.any? }
    end

    private

    def participant(user)
      Participant.new(
        user: user,
        dependents: user.guardian_relationships_as_guardian.sort_by(&:id).map do |relationship|
          related_record(related_user(relationship.dependent_id), relationship.relationship_type, include_applications: true)
        end,
        guardians: user.guardian_relationships_as_dependent.sort_by(&:id).map do |relationship|
          related_record(related_user(relationship.guardian_id), relationship.relationship_type, include_applications: false)
        end,
        application_count: user.applications.size,
        applications_managed_by_other_count: user.applications.count do |application|
          (@user_ids - [user.id]).include?(application.managing_guardian_id)
        end
      )
    end

    def build_direct_relationships
      @users.flat_map(&:guardian_relationships_as_guardian)
            .select { |relationship| @user_ids.include?(relationship.dependent_id) }
            .sort_by(&:id)
            .map do |relationship|
        DirectRelationship.new(
          guardian: @users.find { |user| user.id == relationship.guardian_id },
          dependent: @users.find { |user| user.id == relationship.dependent_id },
          relationship_type: relationship.relationship_type
        )
      end
    end

    def related_user(user_id)
      @related_users_by_id.fetch(user_id)
    end

    def related_record(user, relationship_type, include_applications:)
      applications = include_applications ? ordered_applications(user) : []
      RelatedRecord.new(
        user: user,
        relationship_type: relationship_type,
        applications: applications.first(MAX_APPLICATIONS_PER_DEPENDENT),
        application_count: applications.size
      )
    end

    def build_dependent_outcomes
      grouped = participants.flat_map do |participant|
        participant.dependents.filter_map do |dependent|
          next if @user_ids.include?(dependent.user.id)

          [dependent.user.id, participant.user.id, dependent]
        end
      end.group_by(&:first)

      outcomes = grouped.values.map do |rows|
        dependent = rows.first.last
        DependentOutcome.new(
          user: dependent.user,
          applications: dependent.applications,
          application_count: dependent.application_count,
          linked_from_both: rows.map { |row| row[1] }.uniq.size == @users.size
        )
      end
      outcomes.sort_by { |outcome| outcome.user.id }
    end

    def build_guardian_outcomes
      grouped = participants.flat_map do |participant|
        participant.guardians.filter_map do |guardian|
          next if @user_ids.include?(guardian.user.id)

          [guardian.user.id, participant.user.id, guardian]
        end
      end.group_by(&:first)

      outcomes = grouped.values.map do |rows|
        GuardianOutcome.new(
          user: rows.first.last.user,
          linked_from_both: rows.map { |row| row[1] }.uniq.size == @users.size
        )
      end
      outcomes.sort_by { |outcome| outcome.user.id }
    end

    def ordered_applications(user)
      user.applications.to_a.sort_by { |application| [application.application_date || Date.new(1, 1, 1), application.id] }.reverse
    end
  end
end
