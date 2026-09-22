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

RSpec.describe "Project invite link", :skip_csrf, type: :rails_request do
  shared_let(:project) { create(:project) }
  shared_let(:role) { create(:project_role, permissions: %i[view_work_packages]) }
  shared_let(:manager) do
    create(:user, member_with_permissions: { project => %i[view_members manage_members] })
  end

  let(:turbo_stream_headers) { { "Accept" => "text/vnd.turbo-stream.html" } }

  current_user { manager }

  describe "GET invite_link" do
    it "renders the dialog without a link" do
      get invite_link_project_members_path(project), headers: turbo_stream_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("invite_links.no_link_project"))
      expect(response.body).to include(role.name)
    end

    it "renders the active link of the project" do
      link = create(:invite_link_token, user: manager, project:, role:)
      create(:invite_link_token, user: manager)

      get invite_link_project_members_path(project), headers: turbo_stream_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(account_join_url(token: link.value)))
    end

    it "ignores an expired link" do
      link = create(:invite_link_token, user: manager, project:, role:)
      link.update_column(:expires_on, 1.minute.ago)

      get invite_link_project_members_path(project), headers: turbo_stream_headers

      expect(response.body).not_to include(link.value)
      expect(response.body).to include(I18n.t("invite_links.no_link_project"))
    end

    context "without manage_members" do
      current_user { create(:user, member_with_permissions: { project => %i[view_members] }) }

      it "is forbidden" do
        get invite_link_project_members_path(project), headers: turbo_stream_headers

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "POST create_invite_link" do
    it "creates a link for the chosen role and shows its URL" do
      expect do
        post create_invite_link_project_members_path(project),
             params: { role_id: role.id },
             headers: turbo_stream_headers
      end.to change(Token::InviteLink, :count).by(1)

      link = Token::InviteLink.last
      expect(link.project).to eq project
      expect(link.role).to eq role
      expect(link.user).to eq manager
      expect(response.body).to include(CGI.escapeHTML(account_join_url(token: link.value)))
    end

    it "replaces the previous link of the project" do
      previous = create(:invite_link_token, user: manager, project:, role:)

      post create_invite_link_project_members_path(project),
           params: { role_id: role.id },
           headers: turbo_stream_headers

      expect(Token::InviteLink.where(id: previous.id)).to be_empty
      expect(Token::InviteLink.for_project(project).count).to eq 1
    end

    it "rejects a role that cannot be given to members" do
      work_package_role = create(:view_work_package_role)

      expect do
        post create_invite_link_project_members_path(project),
             params: { role_id: work_package_role.id },
             headers: turbo_stream_headers
      end.not_to change(Token::InviteLink, :count)

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a missing role" do
      expect do
        post create_invite_link_project_members_path(project), headers: turbo_stream_headers
      end.not_to change(Token::InviteLink, :count)

      expect(response).to have_http_status(:bad_request)
    end

    context "without manage_members" do
      current_user { create(:user, member_with_permissions: { project => %i[view_members] }) }

      it "is forbidden" do
        post create_invite_link_project_members_path(project),
             params: { role_id: role.id },
             headers: turbo_stream_headers

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
