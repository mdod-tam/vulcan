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

  test 'legacy Constituent STI row is a paper applicant candidate' do
    user = create(:constituent, email: generate(:email))
    user.update_column(:type, 'Constituent')

    assert User.find(user.id).paper_applicant_candidate?
  end
end
