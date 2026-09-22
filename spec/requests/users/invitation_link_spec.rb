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

RSpec.describe "Users invitation link", :skip_csrf, type: :rails_request do
  shared_let(:admin) { create(:admin) }
  shared_let(:invited_user) { create(:invited_user) }

  let(:turbo_stream_headers) { { "Accept" => "text/vnd.turbo-stream.html" } }

  current_user { admin }

  describe "GET /users/:id/invitation_link" do
    context "with a valid invitation token" do
      let!(:token) { create(:invitation_token, user: invited_user) }

      it "renders the dialog with the activation link" do
        get invitation_link_user_path(invited_user), headers: turbo_stream_headers

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(account_activate_url(token: token.value))
      end
    end

    context "with an expired invitation token" do
      let!(:token) { create(:invitation_token, user: invited_user, expires_on: 1.day.ago) }

      it "renders the dialog without a link" do
        get invitation_link_user_path(invited_user), headers: turbo_stream_headers

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(token.value)
        expect(response.body).to include(I18n.t("users.invitation_link.no_valid_link"))
      end
    end

    context "without an invitation token" do
      it "renders the dialog without a link" do
        get invitation_link_user_path(invited_user), headers: turbo_stream_headers

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("users.invitation_link.no_valid_link"))
      end
    end

    context "with create_user permission" do
      current_user { create(:user, global_permissions: %i[create_user view_all_principals]) }

      it "refuses to reveal the link of an admin" do
        invited_admin = create(:admin, status: User.statuses[:invited])
        create(:invitation_token, user: invited_admin)

        get invitation_link_user_path(invited_admin), headers: turbo_stream_headers

        expect(response).to have_http_status(:forbidden)
      end
    end

    context "without create_user permission" do
      current_user { create(:user) }

      it "is forbidden" do
        get invitation_link_user_path(invited_user), headers: turbo_stream_headers

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "POST /users/:id/generate_invitation_link" do
    it "creates a fresh token and renders the dialog with the new link" do
      old_token = create(:invitation_token, user: invited_user, expires_on: 1.day.ago)

      post generate_invitation_link_user_path(invited_user), headers: turbo_stream_headers

      new_token = Token::Invitation.find_by(user: invited_user)
      expect(response).to have_http_status(:ok)
      expect(new_token.value).not_to eq(old_token.value)
      expect(new_token).not_to be_expired
      expect(response.body).to include(account_activate_url(token: new_token.value))
    end

    it "keeps the user's password and auth links" do
      invited_user.update!(password: "Passw0rd!Passw0rd!", password_confirmation: "Passw0rd!Passw0rd!")

      expect do
        post generate_invitation_link_user_path(invited_user), headers: turbo_stream_headers
      end.not_to change { invited_user.reload.passwords.count }
    end

    context "with create_user permission" do
      current_user { create(:user, global_permissions: %i[create_user view_all_principals]) }

      it "is allowed" do
        post generate_invitation_link_user_path(invited_user), headers: turbo_stream_headers

        expect(response).to have_http_status(:ok)
        expect(Token::Invitation.find_by(user: invited_user)).to be_present
      end

      it "refuses to generate a link for an admin" do
        invited_admin = create(:admin, status: User.statuses[:invited])

        post generate_invitation_link_user_path(invited_admin), headers: turbo_stream_headers

        expect(response).to have_http_status(:forbidden)
        expect(Token::Invitation.find_by(user: invited_admin)).to be_nil
      end
    end

    context "for an active user" do
      let(:active_user) { create(:user) }

      it "is rejected" do
        post generate_invitation_link_user_path(active_user), headers: turbo_stream_headers

        expect(response).to have_http_status(:bad_request)
        expect(Token::Invitation.find_by(user: active_user)).to be_nil
      end
    end

    context "without create_user permission" do
      current_user { create(:user) }

      it "is forbidden" do
        post generate_invitation_link_user_path(invited_user), headers: turbo_stream_headers

        expect(response).to have_http_status(:forbidden)
        expect(Token::Invitation.find_by(user: invited_user)).to be_nil
      end
    end
  end
end
