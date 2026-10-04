# frozen_string_literal: true

require 'mocha/minitest'

# Test doubles for the attachment methods used by this suite.
# An unstubbed method can fail with "unexpected invocation: #<Mock:0x...>.byte_size()".
module AttachmentTestHelper
  # Replace blob storage operations with a service double for the block.
  # @yield Block to execute with mocked attachments
  def with_mocked_attachments(&)
    mock_service = build_mock_service
    ActiveStorage::Blob.stub(:service, mock_service, &)
  end

  # Build the subset of the ActiveStorage service interface used by these tests.
  # @return [Object] A service double for uploads, downloads, URLs, deletion, and existence queries
  def build_mock_service
    Class.new do
      def upload(key, _io, _checksum: nil, **)
        key
      end

      def download(*) = +'fake-content'
      def url(key, **) = "http://example.com/#{key}"
      def delete(*) = true
      def exist?(*) = true

      def open(*)
        StringIO.new('fake-content')
      end

      def url_for(key, _expires_in: nil, disposition: nil, filename: nil, **)
        "http://example.com/#{key}?disposition=#{disposition}&filename=#{filename}"
      end
    end.new
  end

  # Build attachment and blob doubles with the supplied metadata.
  # @param filename [String] The blob filename.
  # @param content_type [String] The blob content type.
  # @param byte_size [Integer] The blob size in bytes.
  # @param created_at [Time] The blob creation time.
  # @param attached [Boolean] Whether the attachment reports as attached.
  # @return [Mocha::Mock] An ActiveStorage::Attached::One double.
  def mock_attached_file(filename: 'test.pdf', content_type: 'application/pdf', byte_size: 100.kilobytes, created_at: Time.current,
                         attached: true)
    filename_obj = ActiveStorage::Filename.new(filename)

    blob_mock = mock("ActiveStorage::Blob #{filename}")
    blob_mock.stubs(:filename).returns(filename_obj)
    blob_mock.stubs(:content_type).returns(content_type)
    blob_mock.stubs(:byte_size).returns(byte_size)
    blob_mock.stubs(:created_at).returns(created_at)
    blob_mock.stubs(:download).returns("Mock content for #{filename}")
    blob_mock.stubs(:url).returns("http://test.host/mock_url_for_#{filename}")
    blob_mock.stubs(:key).returns("mock_key_for_#{filename}")

    attachment_mock = mock("ActiveStorage::Attached::One #{filename}")
    attachment_mock.stubs(:attached?).returns(attached)

    if attached
      attachment_mock.stubs(:blob).returns(blob_mock)
      attachment_mock.stubs(:filename).returns(blob_mock.filename)
      attachment_mock.stubs(:content_type).returns(blob_mock.content_type)
      attachment_mock.stubs(:byte_size).returns(blob_mock.byte_size)
      attachment_mock.stubs(:created_at).returns(blob_mock.created_at)
      attachment_mock.stubs(:download).returns(blob_mock.download)
      attachment_mock.stubs(:url).returns(blob_mock.url)
      attachment_mock.stubs(:key).returns(blob_mock.key)
      attachment_mock.stubs(:purge)
      attachment_mock.stubs(:purge_later)
      attachment_mock.stubs(:attach)
    else
      # Unattached doubles raise on blob access and download.
      attachment_mock.stubs(:blob).raises(ActiveStorage::FileNotFoundError)
      attachment_mock.stubs(:filename).returns(nil)
      attachment_mock.stubs(:content_type).returns(nil)
      attachment_mock.stubs(:byte_size).returns(nil)
      attachment_mock.stubs(:created_at).returns(nil)
      attachment_mock.stubs(:download).raises(ActiveStorage::FileNotFoundError)
      attachment_mock.stubs(:url).returns(nil)
      attachment_mock.stubs(:key).returns(nil)
    end

    attachment_mock
  end
end
