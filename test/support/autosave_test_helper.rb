# frozen_string_literal: true

module AutosaveTestHelper
  def autosave_metadata(actor:, applicant: actor)
    @autosave_test_pages ||= {}
    page = @autosave_test_pages[[actor.id, applicant.id]] ||= {
      context: SecureRandom.uuid, revision: 0
    }
    page[:revision] += 1
    { autosave_context: page[:context], autosave_revision: page[:revision] }
  end
end
