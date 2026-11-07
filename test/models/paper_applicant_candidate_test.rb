# frozen_string_literal: true

require 'test_helper'

class PaperApplicantCandidateTest < ActiveSupport::TestCase
  test 'constituent is a paper applicant candidate' do
    user = create(:constituent, email: generate(:email))
    assert user.paper_applicant_candidate?
  end

  test 'guardian candidate requires an active unmerged constituent' do
    active = create(:constituent)
    suspended = create(:constituent, status: :suspended)
    inactive = create(:constituent, status: :inactive)
    merged = create(:constituent, status: :active, merged_into_user: active)
    admin = create(:admin)

    assert active.paper_guardian_candidate?
    assert_not suspended.paper_guardian_candidate?
    assert_not inactive.paper_guardian_candidate?
    assert_not merged.paper_guardian_candidate?
    assert_not admin.paper_guardian_candidate?
  end

  test 'guardian paper authority is independent of duplicate-review visibility' do
    flagged = create(:constituent, needs_duplicate_review: true)

    assert flagged.paper_guardian_candidate?
  end

  test 'legacy null status remains eligible for guardian paper authority' do
    guardian = create(:constituent)
    guardian.update_column(:status, nil)

    assert guardian.reload.paper_guardian_candidate?
  end

  test 'admin without applicant history is not a candidate' do
    user = create(:admin, email: generate(:email))
    assert_not user.paper_applicant_candidate?
  end

  test 'non-constituent with prior application as subject user is not a candidate' do
    user = create(:evaluator, email: generate(:email), hearing_disability: true)
    assert_not user.paper_applicant_candidate?

    create(:application, :archived, user: user)
    assert_not user.reload.paper_applicant_candidate?
  end

  test 'the candidate scopes agree with the predicates on every standing' do
    matrix = standing_matrix
    ids = matrix.values.map(&:id)
    applicant_ids = User.paper_applicant_candidates.where(id: ids).ids
    guardian_ids = User.paper_guardian_candidates.where(id: ids).ids

    assert_equal matrix.values.select(&:paper_applicant_candidate?).map(&:id).sort, applicant_ids.sort,
                 'the applicant scope must select what paper_applicant_candidate? accepts'
    assert_equal matrix.values.select(&:paper_guardian_candidate?).map(&:id).sort, guardian_ids.sort,
                 'the guardian scope must select what paper_guardian_candidate? accepts'
    assert_equal %i[active inactive legacy_null_status suspended], standings_in(matrix, applicant_ids),
                 'an applicant is any unmerged constituent'
    assert_equal %i[active legacy_null_status], standings_in(matrix, guardian_ids),
                 'a guardian is an unmerged constituent that is neither suspended nor inactive'
  end

  private

  # One user per standing the candidate rules tell apart.
  def standing_matrix
    active = create(:constituent)
    legacy_null_status = create(:constituent)
    legacy_null_status.update_column(:status, nil)

    {
      active: active,
      suspended: create(:constituent, status: :suspended),
      inactive: create(:constituent, status: :inactive),
      merged: create(:constituent, status: :active, merged_into_user: active),
      legacy_null_status: legacy_null_status,
      admin: create(:admin),
      evaluator: create(:evaluator),
      trainer: create(:trainer),
      vendor: create(:vendor)
    }
  end

  def standings_in(matrix, selected_ids)
    matrix.select { |_standing, user| selected_ids.include?(user.id) }.keys.sort
  end
end
