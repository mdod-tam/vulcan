# frozen_string_literal: true

module Applications
  class AutosaveRevisions
    PAGE_ID = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i
    MAX_REVISION = (2**53) - 1
    class InvalidRevision < StandardError; end

    attr_reader :acknowledged_revision

    def initialize(application)
      @application = application
    end

    def form_state(context: nil, revision: nil)
      context = SecureRandom.uuid unless valid_autosave_context?(context)
      page = @application.autosave_revisions.fetch(context, {})
      { context: context, revision: [autosave_revision(revision) || -1, latest_autosave_revision(page)].max + 1 }
    end

    # Both writers hold the participant/application locks and commit this metadata with the values.
    # Full forms remain authoritative, even with older revisions. The browser stamps Save above
    # earlier edits and freezes controls during submission; the server rejects only stale field saves.
    def prepare!(context:, revision:, field: nil)
      revision = autosave_revision(revision)
      unless valid_autosave_context?(context) && revision && (!field || revision.positive?)
        raise InvalidRevision if field

        return :unversioned
      end

      # Other pages may still have delayed requests; their per-field boundaries must survive a Save.
      state = @application.autosave_revisions.deep_dup
      page = state[context] ||= { 'through' => -1, 'fields' => {} }
      @acknowledged_revision = [revision, latest_autosave_revision(page)].max
      if field
        return :superseded if revision <= [page['through'], page['fields'].fetch(field, -1)].max

        page['fields'][field] = revision
      else
        # Even a first full Save needs a boundary: its delayed first autosave may arrive afterwards.
        page['through'] = @acknowledged_revision
        page['fields'].clear
      end
      @application.autosave_revisions = state
      :saved
    end

    private

    def valid_autosave_context?(context)
      context.is_a?(String) && PAGE_ID.match?(context)
    end

    def autosave_revision(value)
      value.to_i if value.to_s.match?(/\A\d{1,16}\z/) && value.to_i <= MAX_REVISION
    end

    def latest_autosave_revision(page)
      [page.fetch('through', -1), *page.fetch('fields', {}).values].max
    end
  end
end
