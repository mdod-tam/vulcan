# frozen_string_literal: true

# Request-replay key for portal-created guardian relationships.
#
# The portal always creates a new dependent (`skip_user_lookup: true`), so a submission that
# reaches the server twice -- double click, lost response, browser retry -- would otherwise create
# a second dependent. The key identifies the *request*, which is what distinguishes a replay from a
# guardian genuinely adding another person; demographic matching answers a different question and
# cannot answer this one.
#
# Nullable because only the portal writer sets it: paper and admin intake create relationships
# through the same model without a request key, and relationships created before this shipped have
# none. The index is partial for that reason.
#
# Uniqueness is scoped to the guardian because that *is* the contract: replay identity is
# (authenticated guardian, request key). A key is one guardian's request namespace, not a global
# value, so the same raw key held by two guardians must be independently spendable. Making the
# index global would couple unrelated accounts -- one guardian's creation could be refused, or
# raise RecordNotUnique under concurrency, because of a random value another account happens to
# hold. Guardian scope makes that unrepresentable rather than caught.
#
# Users::DuplicateMergeService accommodates this index rather than dictating a global one: when a
# guardian retires, its request namespace dies with it, so those keys are cleared as the
# relationships are repointed. See #transfer_guardian_relationships!.
class AddPortalCreationKeyToGuardianRelationships < ActiveRecord::Migration[8.0]
  def change
    add_column :guardian_relationships, :portal_creation_key, :string

    add_index :guardian_relationships,
              %i[guardian_id portal_creation_key],
              unique: true,
              where: 'portal_creation_key IS NOT NULL',
              name: 'index_guardian_relationships_on_guardian_and_creation_key'
  end
end
