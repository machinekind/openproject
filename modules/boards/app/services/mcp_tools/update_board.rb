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
  class UpdateBoard < Base
    include BoardAuthorization

    FILTER_SHAPE_ERROR = 'Each filter must be an object like { "type": { "operator": "=", "values": ["5"] } }.'

    default_title "Update board"
    default_description "Rename a work package board or set the filters applied to all of its lists."

    name "update_board"
    annotations read_only: false, idempotent: true, destructive: true

    input_schema(
      additionalProperties: false,
      required: %i[id],
      properties: {
        id: { type: "number", description: "ID of the board." },
        name: { type: "string", description: "New name of the board." },
        filters: {
          type: "array",
          description: "Filters applied to every list of the board, in the format accepted by APIv3, e.g. " \
                       "[{ \"type\": { \"operator\": \"=\", \"values\": [\"5\"] } }]. The array replaces the " \
                       "filters the board currently has; pass an empty array to remove all of them. An action " \
                       "board rejects a filter on the attribute its lists are built on.",
          items: { type: "object" }
        }
      }
    )

    def call(id:, name: nil, filters: nil)
      return Failure("Pass a name, filters or both.") if name.nil? && filters.nil?

      board_result = authorized_board(id)
      return board_result if board_result.failure?

      board = board_result.value!
      if filters && board.linked.present?
        return Failure("This board is managed by the backlogs module and its filters cannot be changed here.")
      end

      attributes_for(board, name, filters).bind do |attributes|
        format_board(Grids::UpdateService.new(user: current_user, model: board).call(**attributes))
      end
    end

    private

    def attributes_for(board, name, filters)
      return Success({ name: }.compact) if filters.nil?

      normalized_filters(board, filters).fmap do |normalized|
        { name:, options: board.options.to_h.symbolize_keys.merge(filters: normalized) }.compact
      end
    end

    def normalized_filters(board, filters)
      return Failure(FILTER_SHAPE_ERROR) unless filters.all? { |filter| single_condition?(filter) }

      parsed = parse_filters(board, filters)
      return parsed if parsed.failure?

      action_attribute_error(board, parsed.value!) || parsed
    end

    def parse_filters(board, filters)
      query = scratch_query(board)
      result = ::API::V3::UpdateQueryFromV3ParamsService
                 .new(query, current_user)
                 .call({ filters: filters.to_json })

      return Failure(result.errors.full_messages.join(" ")) if result.failure?

      Success(JSON.parse(::API::V3::Queries::QueryParamsRepresenter.new(query).to_h[:filters]))
    end

    def single_condition?(filter)
      filter.is_a?(Hash) && filter.size == 1 && filter.values.first.is_a?(Hash)
    end

    def action_attribute_error(board, normalized)
      names = BoardListFilters::APIV3_NAMES[board.board_type_attribute]
      return nil if names.nil?
      return nil if normalized.none? { |filter| names.intersect?(filter.keys.map(&:to_s)) }

      Failure(BoardListFilters::ACTION_FILTER_ERRORS.fetch(board.board_type_attribute))
    end

    def scratch_query(board)
      Query.new_default(project: board.project, user: current_user).tap { it.filters = [] }
    end
  end
end
