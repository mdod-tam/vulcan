# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

module Applications
  class MedicalCertificationPdfServiceTest < ActiveSupport::TestCase
    PREGENERATED_PDF = Rails.root.join('app/assets/pdfs/medical_certification_form.pdf')

    setup do
      @admin = create(:admin)
      ensure_system_audit_actor!
      @application = create(:application)
    end

    test 'a pregenerated path is handed off as an open, rewound, byte-identical copy that delivery closes' do
      queue_with_isolated_tmpdir(PREGENERATED_PDF) do |result, handoffs, handles, tmpdir|
        assert result.success?
        assert_equal [{ open: true, pos: 0, bytes: File.binread(PREGENERATED_PDF) }], handoffs
        assert_equal File.binread(PREGENERATED_PDF), result.data.pdf_letter.download
        assert_delivery_closed_without_named_artifacts(handles, tmpdir)
      end
    end

    test 'a pregenerated IO is handed off as an open, rewound, byte-identical copy that delivery closes' do
      File.open(PREGENERATED_PDF, 'rb') do |io|
        queue_with_isolated_tmpdir(io) do |result, handoffs, handles, tmpdir|
          assert result.success?
          assert_equal [{ open: true, pos: 0, bytes: File.binread(PREGENERATED_PDF) }], handoffs
          assert_delivery_closed_without_named_artifacts(handles, tmpdir)
        end
      end
    end

    test 'a copy failure before handoff closes the allocated handle and queues nothing' do
      unreadable = Object.new
      %i[read readpartial].each { |reader| unreadable.define_singleton_method(reader) { |*| raise IOError, 'source unreadable' } }

      assert_no_difference ['PrintQueueItem.count', 'ActiveStorage::Blob.count'] do
        queue_with_isolated_tmpdir(unreadable) do |result, handoffs, handles, tmpdir|
          assert_not result.success?
          assert_empty handoffs
          assert_delivery_closed_without_named_artifacts(handles, tmpdir)
        end
      end
    end

    test 'an upload failure after handoff leaves delivery to close the handle and queues nothing' do
      ActiveStorage::Blob.stubs(:create_and_upload!).raises(IOError, 'upload failed')

      assert_no_difference ['PrintQueueItem.count', 'ActiveStorage::Blob.count'] do
        queue_with_isolated_tmpdir(PREGENERATED_PDF) do |result, handoffs, handles, tmpdir|
          assert_not result.success?
          assert_equal 1, handoffs.size
          assert_delivery_closed_without_named_artifacts(handles, tmpdir)
        end
      end
    end

    private

    # Yields the result, what the builder handed off, every handle Tempfile.create allocated, and the
    # isolated temporary directory.
    def queue_with_isolated_tmpdir(source)
      Dir.mktmpdir('dcf-handoff') do |tmpdir|
        original_tmpdir = ENV.fetch('TMPDIR', nil)
        ENV['TMPDIR'] = tmpdir
        handles = record_tempfile_handles
        service = MedicalCertificationPdfService.new(
          application: @application, actor: @admin, pdf_source: { type: :pregenerated, source: source }
        )
        handoffs = record_handoffs(service)
        yield service.call, handoffs, handles, tmpdir
      ensure
        ENV['TMPDIR'] = original_tmpdir
        restore_tempfile_create
      end
    end

    def record_handoffs(service)
      handoffs = []
      builder = service.method(:prepare_pdf_tempfile)
      service.define_singleton_method(:prepare_pdf_tempfile) do
        builder.call.tap do |handle|
          handoffs << { open: !handle.closed?, pos: handle.pos, bytes: handle.read.tap { handle.rewind } }
        end
      end
      handoffs
    end

    def record_tempfile_handles
      handles = []
      @original_tempfile_create = Tempfile.method(:create)
      original = @original_tempfile_create
      Tempfile.define_singleton_method(:create) do |*args, **options, &block|
        original.call(*args, **options, &block).tap { |file| handles << file unless block }
      end
      handles
    end

    def restore_tempfile_create
      Tempfile.define_singleton_method(:create, @original_tempfile_create) if @original_tempfile_create
    end

    # An anonymous file's #path is the directory, so absence is checked by listing the directory.
    def assert_delivery_closed_without_named_artifacts(handles, tmpdir)
      assert_equal 1, handles.size
      assert_predicate handles.first, :closed?
      assert_empty Dir.children(tmpdir)
    end
  end
end
