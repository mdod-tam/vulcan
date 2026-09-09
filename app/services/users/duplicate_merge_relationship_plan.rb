# frozen_string_literal: true

module Users
  # Projects every guardian/dependent edge touching a retiring duplicate onto the
  # canonical survivor. The caller owns the transaction and must supply a complete,
  # row-locked relationship inventory.
  #
  # Distinct relationships survive. Two rows may collapse into one only when they
  # become the exact same guardian/dependent edge and their relationship facts can be
  # represented without discarding live portal replay evidence.
  class DuplicateMergeRelationshipPlan
    Projection = Data.define(:relationship, :guardian_id, :dependent_id) do
      def changed?
        relationship.guardian_id != guardian_id || relationship.dependent_id != dependent_id
      end

      def key
        [guardian_id, dependent_id]
      end
    end

    attr_reader :error

    def initialize(canonical_user:, duplicate_user:, relationships:)
      @canonical_user = canonical_user
      @duplicate_user = duplicate_user
      @relationships = Array(relationships)
      @dissolved = []
      @coalesced = []
      @survivors = []
      @replay_metadata_by_keeper_id = {}
      build
    end

    def valid?
      error.blank?
    end

    def apply!
      raise ArgumentError, error unless valid?

      removed_ids = (@dissolved + @coalesced).map { |projection| projection.relationship.id }
      GuardianRelationship.where(id: removed_ids).delete_all if removed_ids.any?

      transferred = @survivors.count(&:changed?)
      @survivors.each do |projection|
        next unless projection.changed? || @replay_metadata_by_keeper_id.key?(projection.relationship.id)

        apply_projection!(projection)
      end

      {
        guardian_relationships_transferred: transferred,
        guardian_relationships_coalesced: @coalesced.size,
        guardian_relationships_dissolved: @dissolved.size
      }
    end

    private

    def build
      projections = @relationships.map { |relationship| project(relationship) }
      @dissolved, active = projections.partition { |projection| projection.guardian_id == projection.dependent_id }

      active.group_by(&:key).each_value do |group|
        collision_error = collision_error_for(group)
        return @error = collision_error if collision_error

        keeper = keeper_for(group)
        preserve_replay_metadata(group, keeper)
        @survivors << keeper
        @coalesced.concat(group - [keeper])
      end

      @error = contact_priority_error(active) || reciprocal_relationship_error
    end

    def project(relationship)
      Projection.new(
        relationship: relationship,
        guardian_id: projected_user_id(relationship.guardian_id),
        dependent_id: projected_user_id(relationship.dependent_id)
      )
    end

    def projected_user_id(user_id)
      user_id == @duplicate_user.id ? @canonical_user.id : user_id
    end

    def collision_error_for(group)
      return if group.one?

      relationship_types = group.map { |projection| projection.relationship.relationship_type }.uniq
      return 'The same guardian/dependent link has conflicting relationship types; reconcile that relationship before merging' if relationship_types.many?

      return unless dependent_endpoint_collision?(group)
      return unless group.many? { |projection| replay_protected?(projection.relationship) }

      'The same guardian has separately recorded portal links to both dependent records; remove one relationship before merging so replay history is not lost'
    end

    def dependent_endpoint_collision?(group)
      group.map { |projection| projection.relationship.dependent_id }.uniq.many?
    end

    # Prefer the relationship already attached to the canonical record. Besides minimizing writes,
    # its row position preserves the guardian chosen by effective-contact fallback. A sole replay
    # pair from the duplicate-dependent edge is copied onto this keeper after the redundant edge is
    # removed; its guardian namespace remains live, so the evidence is still true. Replay metadata
    # from a retiring guardian belongs to the retiring namespace and is not copied.
    def keeper_for(group)
      group.find { |projection| !projection.changed? } || group.min_by { |projection| projection.relationship.id }
    end

    def preserve_replay_metadata(group, keeper)
      return unless dependent_endpoint_collision?(group)

      replay_source = group.find { |projection| replay_protected?(projection.relationship) }
      return if replay_source.blank? || replay_source == keeper

      @replay_metadata_by_keeper_id[keeper.relationship.id] = {
        portal_creation_key: replay_source.relationship.portal_creation_key,
        portal_creation_fingerprint: replay_source.relationship.portal_creation_fingerprint
      }
    end

    def replay_protected?(relationship)
      relationship.portal_creation_key.present?
    end

    # Guardian fallback currently uses the oldest surviving relationship row. Coalescing or
    # transferring an older row can therefore change the person who receives a dependent's
    # communications even when every relationship remains valid. There is no durable, explicit
    # contact-priority field to update, so fail closed instead of silently changing the recipient.
    def contact_priority_error(active_projections)
      affected_dependent_ids = active_projections.select(&:changed?).map(&:dependent_id).uniq

      affected_dependent_ids.each do |dependent_id|
        expected_guardian_id = expected_contact_guardian_id(active_projections, dependent_id)
        surviving_relationships = @survivors.select { |projection| projection.dependent_id == dependent_id }
        projected_guardian_id = surviving_relationships.min_by { |projection| projection.relationship.id }&.guardian_id
        next if expected_guardian_id.blank? || projected_guardian_id == expected_guardian_id

        return 'Merging would change which guardian receives dependent communications; reconcile guardian contact priority before merging'
      end

      nil
    end

    def expected_contact_guardian_id(active_projections, dependent_id)
      candidates = if dependent_id == @canonical_user.id
                     canonical = original_dependent_projections(active_projections, @canonical_user.id)
                     canonical.presence || original_dependent_projections(active_projections, @duplicate_user.id)
                   else
                     original_dependent_projections(active_projections, dependent_id)
                   end

      candidates.min_by { |projection| projection.relationship.id }&.guardian_id
    end

    def original_dependent_projections(projections, dependent_id)
      projections.select { |projection| projection.relationship.dependent_id == dependent_id }
    end

    def reciprocal_relationship_error
      groups = @survivors.index_by(&:key)
      offending = @survivors.find do |projection|
        reverse = groups[[projection.dependent_id, projection.guardian_id]]
        reverse.present? && reverse != projection && (projection.changed? || reverse.changed?)
      end
      return unless offending

      'Merging would make the survivor and another record guardians of each other; reconcile those relationships before merging'
    end

    def apply_projection!(projection)
      attributes = {
        guardian_id: projection.guardian_id,
        dependent_id: projection.dependent_id
      }

      attributes.merge!(@replay_metadata_by_keeper_id.fetch(projection.relationship.id, {}))

      # A portal replay key is scoped to its guardian. Retiring that guardian ends the
      # namespace; moving the key would falsely claim the request happened on the survivor.
      if projection.relationship.guardian_id == @duplicate_user.id &&
         !@replay_metadata_by_keeper_id.key?(projection.relationship.id)
        attributes[:portal_creation_key] = nil
        attributes[:portal_creation_fingerprint] = nil
      end

      projection.relationship.update!(attributes)
    end
  end
end
