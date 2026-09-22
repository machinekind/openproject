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
  class CreateBoardList < Base
    include BoardAuthorization

    FILTER_KEYS = {
      "status" => :status_id,
      "assignee" => :assigned_to_id,
      "version" => :version_id,
      "subproject" => :only_subproject_id,
      "subtasks" => :parent
    }.freeze

    MISSING_VALUE_ERRORS = {
      "status" => "Pass the value the new list shall show: a status ID.",
      "assignee" => "Pass a value for the list, or null for the list of unassigned work packages.",
      "version" => "Pass the value the new list shall show: a version ID.",
      "subproject" => "Pass the value the new list shall show: a subproject ID.",
      "subtasks" => "Pass the value the new list shall show: the ID of the parent work package."
    }.freeze

    FREE_LIST_NAME = "Unnamed list"
    DUPLICATE_LIST_ERROR = "The board already has a list for this value."

    default_title "Create board list"
    default_description "Add a list (column) to a work package board."

    name "create_board_list"
    annotations read_only: false, idempotent: false, destructive: false

    input_schema(
      additionalProperties: false,
      required: %i[board_id],
      properties: {
        board_id: { type: "number", description: "ID of the board the list is added to." },
        value: {
          type: %w[string number null],
          description: "ID of the value the list is built on: a status on a status board, a user or group on an " \
                       "assignee board, a version on a version board, a subproject on a subproject board and the " \
                       "parent work package on a parent-child board. On an assignee board, pass null for the list " \
                       "of unassigned work packages. A board takes one list per value, so a value that already " \
                       "has a list is rejected. Ignored on a basic board, which has no list attribute."
        },
        name: {
          type: "string",
          description: "Name of the list. Defaults to the name of the value it is built on."
        }
      }
    )

    def call(board_id:, name: nil, **rest)
      board_result = authorized_board(board_id)
      return board_result if board_result.failure?

      board = board_result.value!
      filter_result = list_filter(board, rest)
      return filter_result if filter_result.failure?

      filter, default_name = filter_result.value!

      format_board(add_list(board, filter, name.presence || default_name))
    end

    private

    def free_list_filter
      { manual_sort: { operator: "ow", values: [] } }
    end

    def list_filter(board, rest)
      return Success([free_list_filter, FREE_LIST_NAME]) if board.board_type == :free

      attribute = board.board_type_attribute
      key = FILTER_KEYS[attribute]
      return Failure("Lists cannot be added to a board of this type.") if key.nil?

      value_filter(board, attribute, key, rest)
    end

    def value_filter(board, attribute, key, rest)
      return unassigned_filter(key) if unassigned?(attribute, rest)
      return Failure(MISSING_VALUE_ERRORS.fetch(attribute)) if rest[:value].nil?

      resolve_value(board, attribute, rest[:value]).fmap do |value|
        [{ key => { operator: "=", values: [value.id.to_s] } }, list_name(value)]
      end
    end

    def unassigned?(attribute, rest)
      attribute == "assignee" && rest.key?(:value) && rest[:value].nil?
    end

    def unassigned_filter(key)
      Success([{ key => { operator: "!*", values: [] } }, I18n.t(:label_none)])
    end

    def resolve_value(board, attribute, id)
      case attribute
      when "status" then found(Status.find_by(id:), "The given status could not be found.")
      when "assignee" then assignee_value(board.project, id)
      when "version" then version_value(board.project, id)
      when "subproject" then subproject_value(board.project, id)
      when "subtasks" then parent_value(board.project, id)
      else Failure("Lists cannot be added to a board of this type.")
      end
    end

    def assignee_value(project, id)
      found(Principal.possible_assignee(project).find_by(id:),
            "The given assignee is not available in this project.")
    end

    def version_value(project, id)
      found(project.shared_versions.find_by(id:),
            "The given version is not available in this project.")
    end

    def subproject_value(project, id)
      found(project.descendants.visible(current_user).active.find_by(id:),
            "The given subproject could not be found.")
    end

    def parent_value(project, id)
      found(parent_candidates(project).find_by(id:),
            "The given work package could not be found in this project.")
    end

    def parent_candidates(project)
      WorkPackage
        .visible(current_user)
        .where(project:)
        .where.not(type: Type.where(is_milestone: true))
    end

    def found(value, message)
      value.nil? ? Failure(message) : Success(value)
    end

    def list_name(value)
      value.is_a?(WorkPackage) ? value.subject : value.name
    end

    def add_list(board, filter, name)
      result = nil

      OpenProject::Mutex.with_advisory_lock_transaction(board) do
        board.reload
        result = create_list(board, filter, name)

        raise ActiveRecord::Rollback if result.failure?
      end

      result
    end

    def create_list(board, filter, name)
      return ServiceResult.failure(message: DUPLICATE_LIST_ERROR) if list_exists?(board, filter)

      query_result = Queries::CreateService.new(user: current_user).call(create_query_params(board, filter, name))
      return query_result if query_result.failure?

      widgets = widgets_with_list(board, query_result.result, widget_filter(board, filter))

      Grids::UpdateService
        .new(user: current_user, model: board)
        .call(widgets:, column_count: widgets.size)
    end

    def list_exists?(board, filter)
      names = BoardListFilters::WIDGET_NAMES[board.board_type_attribute]
      return false if board.board_type == :free || names.nil?

      value = list_value(filter.values.first)

      board.widgets.any? do |widget|
        existing = action_condition(widget, names)
        existing && list_value(existing) == value
      end
    end

    def action_condition(widget, names)
      Array(widget.options["filters"])
        .filter_map { it.with_indifferent_access.values_at(*names).compact.first }
        .first
    end

    def list_value(condition)
      Array(condition.with_indifferent_access[:values]).first&.to_s
    end

    def widget_filter(board, filter)
      return filter if board.board_type == :free

      { BoardListFilters::WIDGET_NAMES.fetch(board.board_type_attribute).first.to_sym => filter.values.first }
    end

    def create_query_params(board, filter, name)
      {
        project: board.project,
        public: true,
        sort_criteria: [[:manual_sorting, "asc"], [:id, "asc"]],
        name:,
        filters: [filter]
      }
    end

    def widgets_with_list(board, query, filter)
      ordered = board.widgets.sort_by { [it.start_column, it.id] }

      (ordered + [nil]).each_with_index.map do |widget, index|
        Grids::Widget.new(
          id: widget&.id,
          identifier: "work_package_query",
          start_row: 1,
          end_row: 2,
          start_column: index + 1,
          end_column: index + 2,
          options: widget ? widget.options : { "queryId" => query.id, "filters" => [filter] }
        )
      end
    end
  end
end
