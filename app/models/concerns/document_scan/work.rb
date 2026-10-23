# frozen_string_literal: true

class DocumentScan
  module Work
    extend ActiveSupport::Concern

    WorkItem = Data.define(:token, :action, :provider_scan_id, :blob, :sha256, :byte_size)
    LEASE_DURATION = 5.minutes
    MAX_SUBMISSIONS = 3
    MAX_POLLS = 30
    RESOLUTION_WINDOW = 1.hour

    included do
      scope :due_for_work, lambda {
        pending.where('(next_attempt_at <= :now AND lease_expires_at IS NULL) OR lease_expires_at <= :now', now: Time.current)
      }
    end

    def claim_work!
      with_lock do
        if pending? && lease_available?
          if created_at <= RESOLUTION_WINDOW.ago || (provider_scan_id.nil? && attempts >= MAX_SUBMISSIONS) || poll_count >= MAX_POLLS
            finish_scan!('failed', error_code: 'scan_unresolved')
            nil
          elsif (next_attempt_at && next_attempt_at <= Time.current) || lease_expires_at.present?
            claim_available_slot!
          end
        end
      end
    end

    def expire_unresolved!
      with_lock do
        finish_scan!('failed', error_code: 'scan_unresolved') if pending? && created_at <= RESOLUTION_WINDOW.ago && lease_available?
      end
    end

    def complete_work!(token:, result:)
      with_lock do
        if !pending? || lease_token != token
          false
        elsif provider_scan_id && provider_scan_id != result.scan_id
          finish_scan!('failed', error_code: 'scan_identity_mismatch')
          true
        else
          apply_provider_result!(result)
          true
        end
      end
    end

    def fail_work!(token:, code:, retryable:)
      with_lock do
        if !pending? || lease_token != token
          false
        elsif retryable && attempts < MAX_SUBMISSIONS && poll_count < MAX_POLLS && created_at > RESOLUTION_WINDOW.ago
          update!(lease_token: nil, lease_expires_at: nil, last_error_code: code, next_attempt_at: Time.current + retry_delay)
          true
        else
          finish_scan!('failed', error_code: code)
          true
        end
      end
    end

    private

    def lease_available?
      lease_expires_at.nil? || lease_expires_at <= Time.current
    end

    def claim_available_slot!
      available_at = DocumentScanProviderBudget.try_reserve!
      if available_at > Time.current
        update!(next_attempt_at: available_at)
        nil
      else
        token = SecureRandom.uuid
        action = provider_scan_id ? :poll : :submit
        update!(lease_token: token, lease_expires_at: Time.current + LEASE_DURATION, next_attempt_at: nil,
                attempts: attempts + (action == :submit ? 1 : 0), poll_count: poll_count + (action == :poll ? 1 : 0))
        WorkItem.new(token: token, action: action, provider_scan_id: provider_scan_id, blob: blob, sha256: sha256, byte_size: blob.byte_size)
      end
    end

    def apply_provider_result!(result)
      self.provider_scan_id = result.scan_id
      self.submitted_at ||= Time.current
      case result.status
      when 'pending'
        delay = [30.seconds, 1.minute, 2.minutes].fetch([poll_count, 2].min)
        update!(lease_token: nil, lease_expires_at: nil, last_error_code: nil, next_attempt_at: Time.current + delay)
      when 'ok'
        if result.sha256 == sha256 && result.byte_size == blob.byte_size
          finish_scan!('clean')
        else
          finish_scan!('failed', error_code: 'scan_content_mismatch')
        end
      when 'found', 'warning'
        finish_scan!('blocked', error_code: "scan_#{result.status}")
      when 'failed'
        finish_scan!('failed', error_code: 'provider_scan_failed')
      else
        finish_scan!('failed', error_code: 'unknown_verdict')
      end
    end

    def finish_scan!(value, error_code: nil)
      update!(status: value, completed_at: Time.current, lease_token: nil, lease_expires_at: nil, next_attempt_at: nil, last_error_code: error_code)
      Rails.event.notify('document_scan.completed', document_scan_id: id, status: value, error_code: error_code)
      DocumentSigning::AcceptScannedDocumentJob.perform_later(id) if continuation == 'docuseal'
    end

    def retry_delay
      [30.seconds, 2.minutes, 5.minutes].fetch([attempts - 1, 0].max, 5.minutes)
    end
  end
end
