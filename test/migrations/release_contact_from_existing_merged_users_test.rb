# frozen_string_literal: true

require 'test_helper'
require Rails.root.join('db/migrate/20260713110000_release_contact_from_existing_merged_users').to_s

class ReleaseContactFromExistingMergedUsersTest < ActiveSupport::TestCase
  test 'releases primary contact only from already-merged users' do
    canonical = create(:constituent)
    merged = create(:constituent)
    active = create(:constituent)
    active_contact = active.attributes.slice('email', 'phone')
    merged.update_columns(merged_into_user_id: canonical.id, merged_at: Time.current)

    ReleaseContactFromExistingMergedUsers.new.up

    assert_nil merged.reload.email
    assert_nil merged.phone
    assert_equal active_contact, active.reload.attributes.slice('email', 'phone')
  end

  test 'is irreversible because discarded contact cannot be reconstructed safely' do
    assert_raises(ActiveRecord::IrreversibleMigration) do
      ReleaseContactFromExistingMergedUsers.new.down
    end
  end
end
