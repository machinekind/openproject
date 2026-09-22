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

module McpTools
  class CreateProjectInviteLink < Base
    default_title "Create project invite link"
    default_description "Creates a multi-use invite link for a project. Anyone opening it can register an account " \
                        "and joins the project with the given role. Use the list_roles tool to find the role."

    name "create_project_invite_link"
    annotations read_only: false, idempotent: false, destructive: false

    input_schema(
      additionalProperties: false,
      required: %w[project_id role_id],
      properties: {
        project_id: {
          type: %w[integer string],
          description: "The id or the identifier of the project the link should give access to."
        },
        role_id: {
          type: "integer",
          description: "The id of the project role everyone joining through the link receives."
        }
      }
    )

    def call(project_id:, role_id:)
      project = find_project(project_id)
      return Failure("Project #{project_id} does not exist or is not visible to you.") if project.nil?

      call = ::InviteLinks::CreateService.new(user: current_user, project:).call(role_id:)
      return Failure(call.message) if call.failure?

      Success(payload(call.result))
    end

    private

    def find_project(project_id)
      Project.visible(current_user).active.find_by(id: project_id) ||
        Project.visible(current_user).active.find_by(identifier: project_id.to_s)
    end

    def payload(token)
      {
        url: url_helpers.account_join_url(token: token.value),
        expires_at: token.expires_on.iso8601,
        project: { id: token.project.id, identifier: token.project.identifier, name: token.project.name },
        role: { id: token.role.id, name: token.role.name },
        note: "The link can be used by any number of people and expires after 24 hours. " \
              "Creating a new link revokes the previous link of this project."
      }
    end

    def url_helpers
      @url_helpers ||= OpenProject::StaticRouting::StaticRouter.new.url_helpers
    end
  end
end
