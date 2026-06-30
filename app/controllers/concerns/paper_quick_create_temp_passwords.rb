# frozen_string_literal: true

module PaperQuickCreateTempPasswords
  extend ActiveSupport::Concern

  CACHE_KEY_PREFIX = 'paper_quick_create_temp_password'
  PAPER_QUICK_CREATE_TEMP_PASSWORD_TTL = 30.minutes

  def store_quick_create_temp_password!(user_id, temp_password)
    return if temp_password.blank?

    prune_stale_quick_create_temp_passwords!
    token = SecureRandom.urlsafe_base64(32)
    Rails.cache.write(
      quick_create_temp_password_cache_key(token),
      temp_password,
      expires_in: PAPER_QUICK_CREATE_TEMP_PASSWORD_TTL
    )
    session[:paper_quick_create_temp_passwords] ||= {}
    session[:paper_quick_create_temp_passwords][user_id.to_s] = {
      'token' => token,
      'stored_at' => Time.current.to_i
    }
  end

  def quick_create_temp_passwords
    prune_stale_quick_create_temp_passwords!
    entries = session[:paper_quick_create_temp_passwords] || {}
    entries.each_with_object({}) do |(user_id, entry), passwords|
      password = fetch_quick_create_temp_password(entry)
      passwords[user_id] = password if password.present?
    end
  end

  def quick_create_handoff_user_ids
    prune_stale_quick_create_temp_passwords!
    (session[:paper_quick_create_temp_passwords] || {}).keys
  end

  def clear_quick_create_temp_passwords!
    entries = session[:paper_quick_create_temp_passwords] || {}
    entries.each_value { |entry| delete_cached_quick_create_temp_password(entry) }
    session.delete(:paper_quick_create_temp_passwords)
  end

  private

  def quick_create_temp_password_cache_key(token)
    "#{CACHE_KEY_PREFIX}/#{token}"
  end

  def fetch_quick_create_temp_password(entry)
    token = quick_create_temp_password_token(entry)
    return unless token

    Rails.cache.read(quick_create_temp_password_cache_key(token))
  end

  def delete_cached_quick_create_temp_password(entry)
    token = quick_create_temp_password_token(entry)
    Rails.cache.delete(quick_create_temp_password_cache_key(token)) if token
  end

  def prune_stale_quick_create_temp_passwords!
    return if session[:paper_quick_create_temp_passwords].blank?

    cutoff = PAPER_QUICK_CREATE_TEMP_PASSWORD_TTL.ago.to_i
    session[:paper_quick_create_temp_passwords].delete_if do |_id, entry|
      stale = quick_create_temp_password_stored_at(entry) < cutoff
      delete_cached_quick_create_temp_password(entry) if stale
      stale
    end
  end

  def quick_create_temp_password_token(entry)
    return unless entry.is_a?(Hash)

    entry['token']
  end

  def quick_create_temp_password_stored_at(entry)
    return 0 unless entry.is_a?(Hash)

    entry['stored_at'].to_i
  end
end
