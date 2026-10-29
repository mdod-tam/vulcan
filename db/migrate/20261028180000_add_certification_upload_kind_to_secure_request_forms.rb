# frozen_string_literal: true

# A certification upload request goes to the application's certifying provider, who is not a user. It joins the
# other application-scoped secure links as kind 4 with recipient_role 2: the provider's email is in
# recipient_email and the provider's name in recipient_name. It has no user recipient and no delivery owner.
#
# The two CHECKs hold that in both directions, so a provider row cannot carry a user and a user row cannot
# lose its recipient. The unique index is the database form of the issuer's rule that a new request replaces
# every open one for the application.
class AddCertificationUploadKindToSecureRequestForms < ActiveRecord::Migration[8.0]
  CERTIFICATION_UPLOAD_KIND = 4
  PROVIDER_ROLE = 2

  def up
    change_table :secure_request_forms, bulk: true do |t|
      t.string :recipient_name
      t.change_null :recipient_id, true
    end

    replace_check :secure_request_forms_kind_check, "kind IN (0, 1, 2, 3, #{CERTIFICATION_UPLOAD_KIND})"
    replace_check :secure_request_forms_recipient_role_check, "recipient_role IN (0, 1, #{PROVIDER_ROLE})"
    add_check_constraint :secure_request_forms,
                         "kind <> #{CERTIFICATION_UPLOAD_KIND} OR " \
                         '(recipient_id IS NULL AND delivery_owner_id IS NULL AND delivery_source IS NULL AND ' \
                         "recipient_role = #{PROVIDER_ROLE} AND recipient_channel = 0 AND recipient_email IS NOT NULL)",
                         name: 'secure_request_forms_certification_provider_check'
    add_check_constraint :secure_request_forms,
                         "kind = #{CERTIFICATION_UPLOAD_KIND} OR (recipient_id IS NOT NULL AND recipient_role IN (0, 1))",
                         name: 'secure_request_forms_user_recipient_check'
    add_index :secure_request_forms,
              :application_id,
              unique: true,
              where: "status = 0 AND kind = #{CERTIFICATION_UPLOAD_KIND}",
              name: 'idx_secure_request_forms_one_active_certification_upload'
  end

  # Certification rows cannot exist in the previous shape, so rolling back removes them.
  def down
    remove_index :secure_request_forms, name: 'idx_secure_request_forms_one_active_certification_upload'
    remove_check_constraint :secure_request_forms, name: 'secure_request_forms_user_recipient_check'
    remove_check_constraint :secure_request_forms, name: 'secure_request_forms_certification_provider_check'
    execute "DELETE FROM secure_request_forms WHERE kind = #{CERTIFICATION_UPLOAD_KIND}"
    replace_check :secure_request_forms_recipient_role_check, 'recipient_role IN (0, 1)'
    replace_check :secure_request_forms_kind_check, 'kind IN (0, 1, 2, 3)'
    change_table :secure_request_forms, bulk: true do |t|
      t.change_null :recipient_id, false
      t.remove :recipient_name, type: :string
    end
  end

  private

  def replace_check(name, expression)
    remove_check_constraint :secure_request_forms, name: name
    add_check_constraint :secure_request_forms, expression, name: name
  end
end
