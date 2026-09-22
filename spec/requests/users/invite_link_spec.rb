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

RSpec.describe "Global invite link", :skip_csrf, type: :rails_request do
  shared_let(:admin) { create(:admin) }
  shared_let(:project) { create(:project) }
  shared_let(:role) { create(:project_role) }

  let(:turbo_stream_headers) { { "Accept" => "text/vnd.turbo-stream.html" } }

  current_user { admin }

  describe "GET invite_link" do
    it "renders the dialog without a link" do
      get invite_link_users_path, headers: turbo_stream_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("invite_links.no_link_global"))
    end

    it "renders the active global link" do
      link = create(:invite_link_token, user: admin)
      create(:invite_link_token, user: admin, project:, role:)

      get invite_link_users_path, headers: turbo_stream_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(account_join_url(token: link.value)))
    end

    it "ignores a project scoped link" do
      link = create(:invite_link_token, user: admin, project:, role:)

      get invite_link_users_path, headers: turbo_stream_headers

      expect(response.body).not_to include(link.value)
      expect(response.body).to include(I18n.t("invite_links.no_link_global"))
    end

    context "without create_user permission" do
      current_user { create(:user) }

      it "is forbidden" do
        get invite_link_users_path, headers: turbo_stream_headers

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "POST create_invite_link" do
    it "creates a global link and shows its URL" do
      expect do
        post create_invite_link_users_path, headers: turbo_stream_headers
      end.to change(Token::InviteLink, :count).by(1)

      link = Token::InviteLink.last
      expect(link).to be_global
      expect(link.user).to eq admin
      expect(response.body).to include(CGI.escapeHTML(account_join_url(token: link.value)))
    end

    it "replaces the previous global link but keeps project links" do
      previous = create(:invite_link_token, user: admin)
      project_link = create(:invite_link_token, user: admin, project:, role:)

      post create_invite_link_users_path, headers: turbo_stream_headers

      expect(Token::InviteLink.where(id: previous.id)).to be_empty
      expect(Token::InviteLink.where(id: project_link.id)).to contain_exactly(project_link)
    end

    context "with create_user permission" do
      current_user { create(:user, global_permissions: %i[create_user]) }

      it "is allowed" do
        expect do
          post create_invite_link_users_path, headers: turbo_stream_headers
        end.to change(Token::InviteLink, :count).by(1)
      end
    end

    context "without create_user permission" do
      current_user { create(:user) }

      it "is forbidden" do
        expect do
          post create_invite_link_users_path, headers: turbo_stream_headers
        end.not_to change(Token::InviteLink, :count)

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
