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

module McpTools
  class CreateResourceTool < Base
    class << self
      def model(model_class = nil)
        @model = model_class if model_class

        @model
      end

      def api_name(api_name = nil)
        @api_name = api_name if api_name

        @api_name || model.name.demodulize
      end

      def payload_representer
        "::API::V3::#{api_name.pluralize}::#{api_name}PayloadRepresenter".constantize
      end

      def render_representer
        "::API::V3::#{api_name.pluralize}::#{api_name}Representer".constantize
      end

      def create_service
        "::#{model.name.pluralize}::CreateService".constantize
      end

      def data_input_schema(description)
        input_schema(
          additionalProperties: false,
          required: %i[data],
          properties: {
            data: {
              type: %w[object],
              description:,
              properties: {
                _links: {
                  description: "Contains related resources. They are represented as links, i.e. objects with an 'href' property."
                }
              }
            }
          }
        )
      end
    end

    def call(data:)
      attributes = parse(data)
      result = self.class.create_service.new(user: current_user).call(**service_arguments(attributes))

      if result.success?
        self.class.render_representer.create(result.result, current_user:, embed_links: true)
      else
        { error: result.message }
      end
    end

    private

    def parse(data)
      ::API::V3::ParseResourceParamsService
        .new(current_user, model: self.class.model, representer: self.class.payload_representer)
        .call(data.deep_stringify_keys)
        .result
    end

    def service_arguments(attributes)
      attributes
    end
  end
end
