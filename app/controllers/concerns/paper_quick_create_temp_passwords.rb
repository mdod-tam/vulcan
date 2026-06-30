# frozen_string_literal: true

module PaperQuickCreateTempPasswords
  extend ActiveSupport::Concern

  PAPER_QUICK_CREATE_TEMP_PASSWORD_TTL = 30.minutes

  def store_quick_create_temp_password!(user_id, temp_password)
    prune_stale_quick_create_temp_passwords!
    session[:paper_quick_create_temp_passwords] ||= {}
    session[:paper_quick_create_temp_passwords][user_id.to_s] = {
      'password' => temp_password,
      'stored_at' => Time.current.to_i
    }
  end

  def quick_create_temp_passwords
    prune_stale_quick_create_temp_passwords!
    entries = session[:paper_quick_create_temp_passwords] || {}
    entries.transform_values { |entry| quick_create_temp_password_value(entry) }
  end

  def clear_quick_create_temp_passwords!
    session.delete(:paper_quick_create_temp_passwords)
  end

  private

  def prune_stale_quick_create_temp_passwords!
    return if session[:paper_quick_create_temp_passwords].blank?

    cutoff = PAPER_QUICK_CREATE_TEMP_PASSWORD_TTL.ago.to_i
    session[:paper_quick_create_temp_passwords].delete_if do |_id, entry|
      quick_create_temp_password_stored_at(entry) < cutoff
    end
  end

  def quick_create_temp_password_value(entry)
    entry.is_a?(Hash) ? entry['password'] : entry
  end

  def quick_create_temp_password_stored_at(entry)
    return 0 unless entry.is_a?(Hash)

    entry['stored_at'].to_i
  end
end
