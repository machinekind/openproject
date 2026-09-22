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
  let(:archived_link) { create(:invite_link_token, user: creator, project: create(:project, active: false), role:) }

  def link_to_destroyed_project
    doomed = create(:project)
    create(:invite_link_token, user: creator, project: doomed, role:).tap { doomed.destroy }
  end

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

    it "rejects an invitation token" do
      invitation = create(:invitation_token, user: create(:invited_user))

      get account_join_path(token: invitation.value)

      expect(response).to redirect_to(signin_path)
      expect(flash[:error]).to eq I18n.t("account.invite_link.invalid")
    end

    it "rejects a link whose project was destroyed" do
      get account_join_path(token: link_to_destroyed_project.value)

      expect(response).to redirect_to(signin_path)
      expect(flash[:error]).to eq I18n.t("account.invite_link.invalid")
      expect(session[:invite_link_token]).to be_nil
    end

    context "when already signed in" do
      shared_let(:member) { create(:user) }

      current_user { member }

      it "renders a confirmation instead of creating the membership" do
        expect do
          get account_join_path(token: project_link.value)
        end.not_to change(Member, :count)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(project.name)
        expect(response.body).to include(role.name)
      end

      it "rejects a link whose project was destroyed" do
        get account_join_path(token: link_to_destroyed_project.value)

        expect(response).to redirect_to(signin_path)
        expect(flash[:error]).to eq I18n.t("account.invite_link.invalid")
      end

      it "rejects a link of an archived project" do
        get account_join_path(token: archived_link.value)

        expect(response).to redirect_to(signin_path)
        expect(flash[:error]).to eq I18n.t("account.invite_link.invalid")
      end

      it "only notices a global link" do
        get account_join_path(token: global_link.value)

        expect(response).to redirect_to(home_url)
        expect(flash[:notice]).to eq I18n.t("account.invite_link.already_signed_in")
        expect(member.reload.memberships).to be_empty
      end
    end
  end

  describe "POST /account/join/:token" do
    shared_let(:member) { create(:user) }

    current_user { member }

    it "adds the membership and sends the user to the project" do
      post account_join_project_path(token: project_link.value)

      expect(response).to redirect_to(project_path(project))
      expect(flash[:notice]).to eq I18n.t("account.invite_link.joined_project", project: project.name)
      expect(member.reload.memberships.map(&:project)).to contain_exactly(project)
      expect(project.users).to include(member)
    end

    it "is idempotent" do
      post account_join_project_path(token: project_link.value)
      post account_join_project_path(token: project_link.value)

      expect(member.reload.memberships.count).to eq 1
    end

    it "refuses an archived project" do
      link = archived_link

      expect do
        post account_join_project_path(token: link.value)
      end.not_to change(Member, :count)

      expect(response).to redirect_to(signin_path)
      expect(flash[:error]).to eq I18n.t("account.invite_link.invalid")
    end

    it "refuses a destroyed project" do
      link = link_to_destroyed_project

      expect do
        post account_join_project_path(token: link.value)
      end.not_to change(Member, :count)

      expect(response).to redirect_to(signin_path)
    end

    context "when signed out" do
      current_user { User.anonymous }

      it "remembers the link and sends the visitor to the registration form" do
        post account_join_project_path(token: project_link.value)

        expect(response).to redirect_to(account_register_path)
        expect(session[:invite_link_token]).to eq project_link.value
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

    it "ignores privilege escalating parameters" do
      get account_join_path(token: project_link.value)

      post account_register_path,
           params: {
             user: {
               login: "sneaky",
               mail: "sneaky@example.com",
               firstname: "Jane",
               lastname: "Doe",
               admin: "true",
               status: User.statuses[:active],
               password: "adminADMIN!",
               password_confirmation: "adminADMIN!"
             }
           }

      user = User.find_by(login: "sneaky")
      expect(user).not_to be_admin
      expect(user).to be_active
    end

    it "refuses when the enterprise user limit is reached" do
      get account_join_path(token: project_link.value)
      allow(OpenProject::Enterprise).to receive(:user_limit_reached?).and_return(true)

      register!(login: "overlimit", mail: "overlimit@example.com")

      expect(User.find_by(login: "overlimit")).to be_nil
    end

    it "refuses when the project is archived" do
      archived = create(:project)
      link = create(:invite_link_token, user: creator, project: archived, role:)

      get account_join_path(token: link.value)
      archived.update_column(:active, false)

      register!(login: "archived", mail: "archived@example.com")

      expect(User.find_by(login: "archived")).to be_nil
      expect(response).to redirect_to(signin_url)
    end

    it "refuses when the link was deleted in the meantime" do
      get account_join_path(token: project_link.value)
      project_link.destroy

      register!(login: "stale", mail: "stale@example.com")

      expect(User.find_by(login: "stale")).to be_nil
      expect(response).to redirect_to(signin_url)
    end

    it "refuses when the link expired in the meantime" do
      get account_join_path(token: project_link.value)
      project_link.update_column(:expires_on, 1.minute.ago)

      register!(login: "expired", mail: "expired@example.com")

      expect(User.find_by(login: "expired")).to be_nil
      expect(response).to redirect_to(signin_url)
    end

    it "forgets the link on signout" do
      get account_join_path(token: project_link.value)
      get signout_path

      expect(session[:invite_link_token]).to be_nil

      register!(login: "afterlogout", mail: "afterlogout@example.com")

      expect(User.find_by(login: "afterlogout")).to be_nil
      expect(response).to redirect_to(signin_url)
    end
  end

  describe "POST /account/join/:token without a CSRF token", skip_csrf: false do
    shared_let(:member) { create(:user) }

    current_user { member }

    it "is rejected" do
      expect do
        post account_join_project_path(token: project_link.value)
      end.not_to change(Member, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /account/activate" do
    it "rejects an invite link token" do
      get account_activate_path(token: global_link.value)

      expect(response).to redirect_to(signin_path)
      expect(flash[:error]).to eq I18n.t(:notice_account_invalid_token)
    end
  end
end
