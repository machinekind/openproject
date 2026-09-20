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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

module McpTools
  class ProjectModulesTool < Base
    include Redmine::I18n

    private

    def find_project(project_id)
      ::Project.visible(current_user).find(project_id)
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def modules_payload(project)
      available = OpenProject::AccessControl.available_project_modules(sorted: true)
      extras = project.enabled_module_names.map(&:to_sym) - available

      {
        projectId: project.id,
        projectIdentifier: project.identifier,
        modules: (available + extras).map { |name| module_payload(project, name, available) }
      }
    end

    def module_payload(project, name, available)
      entry = OpenProject::AccessControl.modules.find { |mod| mod[:name] == name }
      feature = OpenProject::AccessControl.module_enterprise_feature?(name).presence

      {
        name: name.to_s,
        label: l_or_humanize(name, prefix: "project_module_"),
        enabled: project.module_enabled?(name),
        available: available.include?(name),
        dependencies: Array(entry&.dig(:dependencies)).map(&:to_s),
        enterpriseFeature: feature,
        enterpriseFeatureAvailable: feature.nil? || EnterpriseToken.allows_to?(feature)
      }
    end

    def assignable_module_names(project)
      OpenProject::AccessControl.available_project_modules.map(&:to_s) | project.enabled_module_names
    end
  end
end
