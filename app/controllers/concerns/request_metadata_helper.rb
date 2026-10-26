# frozen_string_literal: true

# Builds request metadata (IP address, user agent, controller, action) for audit events and logs.
module RequestMetadataHelper
  extend ActiveSupport::Concern

  private

  # Builds basic request metadata hash
  # @return [Hash] Standard metadata with IP address and user agent
  def basic_request_metadata
    {
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    }
  end

  # Builds audit metadata for events and logs
  # @param additional_data [Hash] Additional metadata to merge
  # @return [Hash] Audit metadata with request info and optional additional data
  def audit_metadata(additional_data = {})
    basic_request_metadata.merge(
      timestamp: Time.current.iso8601,
      controller: controller_name,
      action: action_name
    ).merge(additional_data)
  end

  # Builds metadata specifically for proof submissions
  # @param proof_type [String] Type of proof being submitted
  # @param additional_data [Hash] Additional metadata to merge
  # @return [Hash] Proof submission metadata
  def proof_submission_metadata(proof_type, additional_data = {})
    basic_request_metadata.merge(
      proof_type: proof_type,
      submission_timestamp: Time.current.iso8601
    ).merge(additional_data)
  end
end
