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

require "rails_helper"

RSpec.describe Users::InvitationLinkDialogComponent, type: :component do
  include Rails.application.routes.url_helpers

  shared_let(:user) { create(:invited_user) }

  subject(:render_dialog) { render_inline(described_class.new(user:)) }

  context "with a valid token" do
    let!(:token) { create(:invitation_token, user:) }
    let(:activation_url) { account_activate_url(token: token.value, host: Setting.host_name) }

    it "shows the activation link with a copy button" do
      render_dialog

      expect(page).to have_test_selector("invitation-link", text: activation_url)
      expect(page).to have_css("clipboard-copy[value='#{activation_url}']")
      expect(page).to have_text(I18n.t("users.invitation_link.description", name: user.name))
      expect(page).to have_test_selector("generate-invitation-link", text: I18n.t("users.invitation_link.generate"))
    end
  end

  context "with an expired token" do
    let!(:token) { create(:invitation_token, user:, expires_on: 1.day.ago) }

    it "does not show the link" do
      render_dialog

      expect(page).to have_no_text(token.value)
      expect(page).to have_text(I18n.t("users.invitation_link.no_valid_link"))
      expect(page).to have_test_selector("generate-invitation-link")
    end
  end

  context "without a token" do
    it "offers to generate one" do
      render_dialog

      expect(page).to have_text(I18n.t("users.invitation_link.no_valid_link"))
      expect(page).to have_css("form[action='#{generate_invitation_link_user_path(user)}']")
    end
  end
end
