# frozen_string_literal: true

module PaperQuickCreatePortalMarkers
  extend ActiveSupport::Concern

  PAPER_QUICK_CREATE_PORTAL_MARKER_TTL = 30.minutes
  SESSION_KEY = 'paper_quick_created_portal_users'

  def store_quick_created_portal_user_marker!(user)
    return unless user&.portal_access_eligible?

    prune_stale_quick_created_portal_user_markers!
    session[SESSION_KEY] ||= {}
    session[SESSION_KEY][user.id.to_s] = {
      'stored_at' => Time.current.to_i
    }
  end

  def quick_created_portal_user_ids
    prune_stale_quick_created_portal_user_markers!
    (session[SESSION_KEY] || {}).keys
  end

  def clear_quick_created_portal_user_markers!
    session.delete(SESSION_KEY)
  end

  private

  def prune_stale_quick_created_portal_user_markers!
    return if session[SESSION_KEY].blank?

    cutoff = PAPER_QUICK_CREATE_PORTAL_MARKER_TTL.ago.to_i
    session[SESSION_KEY].delete_if do |_user_id, entry|
      quick_created_portal_user_marker_stored_at(entry) < cutoff
    end
  end

  def quick_created_portal_user_marker_stored_at(entry)
    return 0 unless entry.is_a?(Hash)

    entry['stored_at'].to_i
  end
end
