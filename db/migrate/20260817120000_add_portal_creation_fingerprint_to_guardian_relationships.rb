# frozen_string_literal: true

# Request fingerprint that accompanies `portal_creation_key`.
#
# The key alone answers "have I seen this request id before". It cannot answer "is this the *same*
# operation", and that gap is user-visible: a resubmission carrying a spent key but changed contact
# details would otherwise be reported as "already added" while the changes were silently discarded.
# A replay key means "repeat this creation operation", so any change to what would be persisted has
# to surface as a stale-request refusal instead.
#
# Stored as a versioned, server-keyed HMAC rather than a plain digest. The inputs include encrypted
# and partly low-entropy PII -- a date of birth, a phone number -- and a plain SHA of those is
# effectively a searchable index into them: anyone holding the column could confirm a guess by
# recomputing. Keying the digest to the application's secret removes that, and the version prefix
# lets the canonical form change later without silently matching old rows.
#
# The two columns are meaningless apart, so the check constraint keeps them present or absent
# together; only the portal writer sets either.
class AddPortalCreationFingerprintToGuardianRelationships < ActiveRecord::Migration[8.0]
  def change
    add_column :guardian_relationships, :portal_creation_fingerprint, :string

    add_check_constraint :guardian_relationships,
                         '(portal_creation_key IS NULL) = (portal_creation_fingerprint IS NULL)',
                         name: 'guardian_relationships_portal_creation_pair_check'
  end
end
