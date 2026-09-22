# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "spec_helper"

RSpec.describe Token::InviteLink do
  shared_let(:creator) { create(:admin) }
  shared_let(:project) { create(:project) }
  shared_let(:other_project) { create(:project) }
  shared_let(:role) { create(:project_role) }

  describe "expiry" do
    it "is valid for 24 hours" do
      token = described_class.create!(user: creator)

      expect(token.expires_on).to be_within(1.minute).of(24.hours.from_now)
      expect(token).not_to be_expired
    end

    it "is expired once the expiry has passed" do
      token = described_class.create!(user: creator)
      token.update_column(:expires_on, 1.minute.ago)

      expect(token.reload).to be_expired
    end
  end

  describe "value" do
    it "is prefixed so it can be recognized" do
      expect(described_class.create!(user: creator).value).to start_with("join-")
    end
  end

  describe "scope" do
    it "is global without a project" do
      token = described_class.create!(user: creator)

      expect(token).to be_global
      expect(token.project).to be_nil
      expect(token.role).to be_nil
    end

    it "resolves project and role when scoped" do
      token = described_class.create!(user: creator, project_id: project.id, role_id: role.id)

      expect(token).not_to be_global
      expect(token.project).to eq project
      expect(token.role).to eq role
    end
  end

  describe "#usable?" do
    it "is usable when global and not expired" do
      expect(described_class.create!(user: creator)).to be_usable
    end

    it "is not usable once expired" do
      token = described_class.create!(user: creator)
      token.update_column(:expires_on, 1.minute.ago)

      expect(token.reload).not_to be_usable
    end

    it "is not usable when the project is archived" do
      archived = create(:project, active: false)
      token = described_class.create!(user: creator, project_id: archived.id, role_id: role.id)

      expect(token).not_to be_usable
      expect(token.project).to be_nil
    end

    it "is not usable when the project is gone" do
      doomed = create(:project)
      token = described_class.create!(user: creator, project_id: doomed.id, role_id: role.id)
      doomed.destroy

      expect(token.reload).not_to be_usable
    end

    it "is not usable when the role is no longer givable" do
      builtin = create(:non_member)
      token = described_class.create!(user: creator, project_id: project.id, role_id: builtin.id)

      expect(token).not_to be_usable
      expect(token.role).to be_nil
    end
  end

  describe ".find_usable" do
    it "finds a usable token by its plaintext value" do
      token = described_class.create!(user: creator)

      expect(described_class.find_usable(token.value)).to eq token
    end

    it "returns nil for an unusable token" do
      archived = create(:project, active: false)
      token = described_class.create!(user: creator, project_id: archived.id, role_id: role.id)

      expect(described_class.find_usable(token.value)).to be_nil
    end

    it "returns nil for an unknown value" do
      expect(described_class.find_usable("join-nope")).to be_nil
    end
  end

  describe ".global" do
    it "only returns links without a project" do
      global = described_class.create!(user: creator)
      described_class.create!(user: creator, project_id: project.id, role_id: role.id)

      expect(described_class.global).to contain_exactly(global)
    end
  end

  describe ".for_project" do
    it "only returns links of that project" do
      scoped = described_class.create!(user: creator, project_id: project.id, role_id: role.id)
      described_class.create!(user: creator, project_id: other_project.id, role_id: role.id)
      described_class.create!(user: creator)

      expect(described_class.for_project(project)).to contain_exactly(scoped)
    end
  end

  describe ".active" do
    it "excludes expired links" do
      active = described_class.create!(user: creator)
      expired = described_class.create!(user: creator, project_id: project.id, role_id: role.id)
      expired.update_column(:expires_on, 1.minute.ago)

      expect(described_class.active).to contain_exactly(active)
    end
  end

  describe "revoking on create" do
    it "revokes the previous link of the same project" do
      previous = described_class.create!(user: creator, project_id: project.id, role_id: role.id)
      current = described_class.create!(user: creator, project_id: project.id, role_id: role.id)

      expect(described_class.where(id: previous.id)).to be_empty
      expect(described_class.for_project(project)).to contain_exactly(current)
    end

    it "revokes the previous global link" do
      previous = described_class.create!(user: creator)
      current = described_class.create!(user: creator)

      expect(described_class.where(id: previous.id)).to be_empty
      expect(described_class.global).to contain_exactly(current)
    end

    it "leaves links of other scopes alone" do
      global = described_class.create!(user: creator)
      other = described_class.create!(user: creator, project_id: other_project.id, role_id: role.id)

      described_class.create!(user: creator, project_id: project.id, role_id: role.id)

      expect(described_class.where(id: [global.id, other.id]).count).to eq 2
    end

    it "does not revoke links of other creators in a different scope" do
      other_creator = create(:user)
      kept = described_class.create!(user: other_creator, project_id: other_project.id, role_id: role.id)

      described_class.create!(user: creator, project_id: project.id, role_id: role.id)

      expect(described_class.where(id: kept.id)).to contain_exactly(kept)
    end

    it "revokes a link of the same scope even when created by someone else" do
      other_creator = create(:user)
      replaced = described_class.create!(user: other_creator, project_id: project.id, role_id: role.id)

      described_class.create!(user: creator, project_id: project.id, role_id: role.id)

      expect(described_class.where(id: replaced.id)).to be_empty
    end
  end
end
