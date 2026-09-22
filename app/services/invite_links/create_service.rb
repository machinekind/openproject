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

module InviteLinks
  class CreateService
    attr_reader :user, :project

    def initialize(user:, project: nil)
      @user = user
      @project = project
    end

    def call(role_id: nil)
      return unauthorized unless allowed?

      role = givable_role(role_id)
      return invalid_role if project && role.nil?

      token = ::Token::InviteLink.create!(user:, project_id: project&.id, role_id: role&.id)

      ServiceResult.success(result: token)
    end

    private

    def allowed?
      if project
        user.allowed_in_project?(:manage_members, project)
      else
        user.allowed_globally?(:create_user)
      end
    end

    def givable_role(role_id)
      return if project.nil? || role_id.blank?

      ProjectRole.givable.find_by(id: role_id)
    end

    def invalid_role
      ServiceResult.failure(message: I18n.t("invite_links.error_invalid_role"))
    end

    def unauthorized
      ServiceResult.failure(message: I18n.t("invite_links.error_not_authorized"))
    end
  end
end
