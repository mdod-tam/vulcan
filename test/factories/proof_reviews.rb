# frozen_string_literal: true

FactoryBot.define do
  # A direct attachment row leaves the application's loaded attachment association stale, so attached? still reads false.
  reset_attachment = ->(application, name) { application.association(:"#{name}_attachment").reset }

  factory :proof_review do
    application factory: %i[application]
    admin
    proof_type { :income }
    status { :approved }
    reviewed_at { Time.current }

    after(:build) do |proof_review|
      next if proof_review.proof_type.blank? || proof_review.application.document_attachment_for(proof_review.proof_type).attached?

      original_context = Thread.current[:paper_application_context]
      Thread.current[:paper_application_context] = true

      begin
        fixture_dir = Rails.root.join('test/fixtures/files')
        FileUtils.mkdir_p(fixture_dir)

        proof_filename = case proof_review.proof_type
                         when 'income' then 'test_income_proof.pdf'
                         when 'residency' then 'test_residency_proof.pdf'
                         else 'test_proof.pdf'
                         end

        file_path = fixture_dir.join(proof_filename)
        File.write(file_path, "test content for #{proof_filename}") unless File.exist?(file_path)

        blob = ActiveStorage::Blob.create_and_upload!(
          io: File.open(file_path),
          filename: proof_filename,
          content_type: 'application/pdf'
        )

        blob.update_column(:created_at, 2.minutes.ago)

        proof_type = proof_review.proof_type.to_sym
        attachment_name = DocumentType.fetch(proof_type).attachment_name

        # A direct attachment row does not save the persisted application.
        if proof_review.application.persisted?
          ActiveStorage::Attachment.create(
            name: attachment_name.to_s,
            record_type: 'Application',
            record_id: proof_review.application.id,
            blob_id: blob.id
          )
          reset_attachment.call(proof_review.application, attachment_name)

          if ProofReview.reviewable_proof_type?(proof_type)
            proof_review.application.update_column(
              "#{proof_type}_proof_status",
              Application.public_send("#{proof_type}_proof_statuses")[proof_review.status.to_s]
            )
          end
        else
          proof_review.application.public_send(attachment_name).attach(blob)
        end
      ensure
        Thread.current[:paper_application_context] = original_context
      end
    end

    trait :approved do
      status { :approved }
    end

    trait :rejected do
      status { :rejected }
      rejection_reason { 'Invalid documentation' }
    end

    trait :with_income_proof do
      proof_type { :income }
      after(:build) do |proof_review|
        next if proof_review.application.income_proof.attached?

        original_context = Thread.current[:paper_application_context]
        Thread.current[:paper_application_context] = true

        begin
          fixture_dir = Rails.root.join('test/fixtures/files')
          file_path = fixture_dir.join('test_income_proof.pdf')
          File.write(file_path, 'test content for income proof') unless File.exist?(file_path)

          blob = ActiveStorage::Blob.create_and_upload!(
            io: File.open(file_path),
            filename: 'test_income_proof.pdf',
            content_type: 'application/pdf'
          )

          blob.update_column(:created_at, 2.minutes.ago)

          # A direct attachment row does not save the persisted application.
          if proof_review.application.persisted?
            ActiveStorage::Attachment.create(
              name: 'income_proof',
              record_type: 'Application',
              record_id: proof_review.application.id,
              blob_id: blob.id
            )
            reset_attachment.call(proof_review.application, :income_proof)
          else
            proof_review.application.income_proof.attach(blob)
          end
        ensure
          Thread.current[:paper_application_context] = original_context
        end
      end
    end

    trait :with_residency_proof do
      proof_type { :residency }
      after(:build) do |proof_review|
        next if proof_review.application.residency_proof.attached?

        original_context = Thread.current[:paper_application_context]
        Thread.current[:paper_application_context] = true

        begin
          fixture_dir = Rails.root.join('test/fixtures/files')
          file_path = fixture_dir.join('test_residency_proof.pdf')
          File.write(file_path, 'test content for residency proof') unless File.exist?(file_path)

          blob = ActiveStorage::Blob.create_and_upload!(
            io: File.open(file_path),
            filename: 'test_residency_proof.pdf',
            content_type: 'application/pdf'
          )

          blob.update_column(:created_at, 2.minutes.ago)

          # A direct attachment row does not save the persisted application.
          if proof_review.application.persisted?
            ActiveStorage::Attachment.create(
              name: 'residency_proof',
              record_type: 'Application',
              record_id: proof_review.application.id,
              blob_id: blob.id
            )
            reset_attachment.call(proof_review.application, :residency_proof)
          else
            proof_review.application.residency_proof.attach(blob)
          end
        ensure
          Thread.current[:paper_application_context] = original_context
        end
      end
    end
  end
end
