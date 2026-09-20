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

module API
  module V3
    module Types
      class TypesByWorkspaceAPI < ::API::OpenProjectAPI
        resources :types do
          helpers do
            def requested_type
              fail ::API::Errors::InvalidRequestBody.new(I18n.t("api_v3.errors.missing_request_body")) unless request_body

              representer = EnabledTypeRepresenter.create(::API::ParserStruct.new, current_user:)
              representer.from_hash(request_body)

              ::Type.find_by(id: representer.represented.type_id.to_i)
            end

            def apply_service(service_class, variant)
              result = service_class.new(user: current_user, model: @project).call(variant:)

              raise ::API::Errors::ErrorBase.create_and_merge_errors(result.errors) if result.failure?
            end
          end

          after_validation do
            authorize_in_project %i[view_work_packages manage_types], project: @project
          end

          get do
            TypeCollectionRepresenter.new(@project.enabled_types,
                                          self_link: api_v3_paths.types_by_workspace(@project.id),
                                          current_user:)
          end

          post do
            authorize_in_project :manage_types, project: @project

            type = requested_type
            variant = type&.default_variant
            raise ::API::Errors::NotFound if variant.nil?

            already_enabled = @project.project_types.exists?(type_id: type.id)
            apply_service(::Projects::Types::AddService, variant)
            status(200) if already_enabled

            TypeRepresenter.create(type, current_user:)
          end

          route_param :type_id, type: Integer, desc: "Type ID" do
            delete do
              authorize_in_project :manage_types, project: @project

              type = ::Type.find_by(id: params[:type_id])
              raise ::API::Errors::NotFound if type.nil? || !@project.project_types.exists?(type_id: type.id)

              apply_service(::Projects::Types::RemoveService, @project.type_variant(type))

              status 204
            end
          end
        end
      end
    end
  end
end
