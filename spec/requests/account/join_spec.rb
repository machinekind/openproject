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

RSpec.describe "Joining through an invite link", :skip_csrf, type: :rails_request do
  shared_let(:creator) { create(:admin) }
  shared_let(:project) { create(:project) }
  shared_let(:role) { create(:project_role, permissions: %i[view_work_packages]) }

  let(:project_link) { create(:invite_link_token, user: creator, project:, role:) }
  let(:global_link) { create(:invite_link_token, user: creator) }

  def register!(login:, mail:)
    post account_register_path,
         params: {
           user: {
             login:,
             mail:,
             firstname: "Jane",
             lastname: "Doe",
             password: "adminADMIN!",
             password_confirmation: "adminADMIN!"
           }
         }
  end

  describe "GET /account/join/:token" do
    it "remembers the link and sends the visitor to the registration form" do
      get account_join_path(token: project_link.value)

      expect(response).to redirect_to(account_register_path)
      expect(session[:invite_link_token]).to eq project_link.value
    end

    it "rejects an expired link" do
      project_link.update_column(:expires_on, 1.minute.ago)

      get account_join_path(token: project_link.value)

      expect(response).to redirect_to(signin_path)
      expect(flash[:error]).to eq I18n.t("account.invite_link.invalid")
      expect(session[:invite_link_token]).to be_nil
    end

    it "rejects an unknown link" do
      get account_join_path(token: "join-does-not-exist")

      expect(response).to redirect_to(signin_path)
      expect(flash[:error]).to eq I18n.t("account.invite_link.invalid")
    end

    context "when already signed in" do
      shared_let(:member) { create(:user) }

      current_user { member }

      it "adds the membership and sends the user to the project" do
        get account_join_path(token: project_link.value)

        expect(response).to redirect_to(project_path(project))
        expect(flash[:notice]).to eq I18n.t("account.invite_link.joined_project", project: project.name)
        expect(member.reload.memberships.map(&:project)).to contain_exactly(project)
        expect(project.users).to include(member)
      end

      it "is idempotent" do
        get account_join_path(token: project_link.value)
        get account_join_path(token: project_link.value)

        expect(member.reload.memberships.count).to eq 1
      end

      it "only notices a global link" do
        get account_join_path(token: global_link.value)

        expect(response).to redirect_to(home_url)
        expect(flash[:notice]).to eq I18n.t("account.invite_link.already_signed_in")
        expect(member.reload.memberships).to be_empty
      end
    end
  end

  describe "registering through the link",
           with_settings: { self_registration: Setting::SelfRegistration.disabled } do
    it "activates the account and adds the project membership" do
      get account_join_path(token: project_link.value)
      expect(response).to redirect_to(account_register_path)

      get account_register_path
      expect(response).to have_http_status(:ok)

      register!(login: "joiner", mail: "joiner@example.com")

      user = User.find_by(login: "joiner")
      expect(user).to be_active
      expect(user.memberships.map(&:project)).to contain_exactly(project)
      expect(user.memberships.first.roles).to contain_exactly(role)
      expect(session[:invite_link_token]).to be_nil
    end

    it "stays usable for the next registrant" do
      get account_join_path(token: project_link.value)
      register!(login: "first", mail: "first@example.com")
      get signout_path

      get account_join_path(token: project_link.value)
      register!(login: "second", mail: "second@example.com")

      second = User.find_by(login: "second")
      expect(second).to be_active
      expect(second.memberships.map(&:project)).to contain_exactly(project)
    end

    it "activates the account without a membership for a global link" do
      get account_join_path(token: global_link.value)
      register!(login: "global", mail: "global@example.com")

      user = User.find_by(login: "global")
      expect(user).to be_active
      expect(user.memberships).to be_empty
    end

    it "refuses to register without a link" do
      register!(login: "nolink", mail: "nolink@example.com")

      expect(User.find_by(login: "nolink")).to be_nil
      expect(response).to redirect_to(signin_url)
    end
  end
end
