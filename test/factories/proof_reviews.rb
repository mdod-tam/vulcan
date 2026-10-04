# frozen_string_literal: true

FactoryBot.define do
  factory :proof_review do
    application factory: %i[application]
    admin
    proof_type { :income }
    status { :approved }
    reviewed_at { Time.current }

    after(:build) do |proof_review|
      # This guard does not verify an ID or medical certification attachment.
      next if proof_review.application.income_proof.attached? && proof_review.application.residency_proof.attached?

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

        # A direct attachment row does not save the persisted application.
        if proof_review.application.persisted?
          ActiveStorage::Attachment.create(
            name: "#{proof_type}_proof",
            record_type: 'Application',
            record_id: proof_review.application.id,
            blob_id: blob.id
          )

          proof_review.application.update_column(
            "#{proof_type}_proof_status",
            Application.public_send("#{proof_type}_proof_statuses")[proof_review.status.to_s]
          )
        else
          proof_review.application.public_send(:"#{proof_type}_proof").attach(blob)
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
