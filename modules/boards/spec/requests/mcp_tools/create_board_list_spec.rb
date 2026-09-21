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

require "spec_helper"

RSpec.describe McpTools::CreateBoardList do
  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) { create(:oauth_access_token, scopes: "mcp", resource_owner: user) }
  let(:user) { create(:user, member_with_permissions: { project => permissions }) }
  let(:permissions) { %i[view_work_packages show_board_views manage_board_views manage_public_queries save_queries] }
  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: {
        name: "create_board_list",
        arguments: call_args
      }
    }
  end
  let(:call_args) { { board_id: board.id } }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:result_item) { parsed_results.fetch("structuredContent") }

  let(:project) { create(:project) }
  let(:board) { create(:board_grid, project:) }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    server_config.save!
    tool_config.save!
  end

  def action_board(service_class, attribute)
    User.execute_as(user) do
      service_class.new(user:).call(project:, name: "My board", attribute:).result
    end
  end

  shared_examples_for "a created list" do
    it "appends a list backed by a new public query" do
      existing = board.widgets.sort_by { [it.start_column, it.id] }.map { [it.id, it.options] }

      expect { mcp_request }.to change { board.reload.widgets.count }.by(1)

      widgets = board.widgets.sort_by(&:start_column)
      expect(widgets.first(existing.size).map { [it.id, it.options] }).to eq(existing)
      expect(widgets.map(&:start_column)).to eq((1..widgets.size).to_a)
      expect(widgets.map(&:end_column)).to eq((2..(widgets.size + 1)).to_a)
      expect(board.column_count).to eq(widgets.size)

      new_widget = widgets.last
      expect(new_widget.identifier).to eq("work_package_query")
      expect(new_widget.options["filters"]).to eq([expected_filter])

      query = Query.find(new_widget.options["queryId"])
      expect(query.name).to eq(expected_name)
      expect(query).to be_public
      expect(query.project).to eq(project)
      expect(query.sort_criteria).to eq([%w[manual_sorting asc], %w[id asc]])
    end
  end

  shared_examples_for "a rejected list" do
    it "responds with an error and changes nothing" do
      widget_count = board.reload.widgets.count
      query_count = Query.count

      mcp_request

      expect(Query.count).to eq(query_count)
      expect(board.reload.widgets.count).to eq(widget_count)
      expect(result_item.fetch("error")).to eq(expected_error)
    end
  end

  def new_list
    widget = board.reload.widgets.max_by(&:start_column)

    [widget, Query.find(widget.options["queryId"])]
  end

  context "when the MCP server is enabled" do
    it_behaves_like "MCP text tool"

    context "with a basic board" do
      let(:expected_filter) { { manual_sort: { operator: "ow", values: [] } } }
      let(:expected_name) { "Unnamed list" }

      it_behaves_like "a created list"

      it "responds with the rendered grid" do
        mcp_request

        expect(result_item.fetch("_type")).to eq("Grid")
        expect(result_item.dig("_links", "self", "href")).to eq("/api/v3/grids/#{board.id}")
      end

      context "when passing a name" do
        let(:call_args) { { board_id: board.id, name: "Ideas" } }
        let(:expected_name) { "Ideas" }

        it_behaves_like "a created list"
      end

      context "when another request added a list after the board was loaded" do
        let(:board) { create(:board_grid_with_query, project:) }
        let(:stale_board) { Boards::Grid.find(board.id).tap { it.widgets.load } }

        def stub_loaded_board(loaded_board)
          allow(described_class).to receive(:new).and_wrap_original do |original, **args|
            original.call(**args).tap do |tool|
              allow(tool).to receive(:authorized_board).and_return(Dry::Monads::Success(loaded_board))
            end
          end
        end

        it "places the list after the one added in the meantime and leaves a valid board" do
          stale_board
          header "Authorization", "Bearer #{access_token.plaintext_token}"
          header "Content-Type", "application/json"
          post "/mcp", request_body.to_json

          stub_loaded_board(stale_board)
          post "/mcp", request_body.to_json

          widgets = board.reload.widgets.sort_by(&:start_column)
          expect(widgets.map { [it.start_column, it.end_column] }).to eq([[1, 2], [2, 3], [3, 4]])
          expect(board.column_count).to eq(3)
          expect(Grids::UpdateService.new(user:, model: board).call(name: "Renamed")).to be_success
        end
      end
    end

    context "with a board that already has misaligned widgets" do
      let(:board) { create(:board_grid_with_queries, project:) }
      let(:expected_filter) { { manual_sort: { operator: "ow", values: [] } } }
      let(:expected_name) { "Unnamed list" }

      it_behaves_like "a created list"

      it "repairs the columns of the existing widgets" do
        mcp_request

        widgets = board.reload.widgets.sort_by(&:start_column)
        expect(widgets.map { |w| [w.start_column, w.end_column] }).to eq([[1, 2], [2, 3], [3, 4]])
        expect(board.column_count).to eq(3)
      end
    end

    context "with a status board" do
      let!(:default_status) { create(:default_status) }
      let!(:status) { create(:status, name: "In progress") }
      let(:board) { action_board(Boards::StatusBoardCreateService, "status") }
      let(:call_args) { { board_id: board.id, value: status.id } }
      let(:expected_filter) { { status_id: { operator: "=", values: [status.id.to_s] } } }
      let(:expected_name) { "In progress" }

      it_behaves_like "a created list"

      context "when the board already has a list for the status" do
        let(:call_args) { { board_id: board.id, value: default_status.id } }
        let(:expected_error) { "The board already has a list for this value." }

        it_behaves_like "a rejected list"
      end

      context "when the status does not exist" do
        let(:call_args) { { board_id: board.id, value: 0 } }
        let(:expected_error) { "The given status could not be found." }

        it_behaves_like "a rejected list"
      end
    end

    context "with a board linked to a sprint" do
      let!(:status) { create(:status, name: "In progress") }
      let(:sprint) { create(:sprint, project:) }
      let(:board) do
        create(:board_grid,
               project:,
               name: "Task board",
               linked: sprint,
               options: { type: "action",
                          attribute: "status",
                          filters: [{ sprint_id: { operator: "=", values: [sprint.id.to_s] } }] })
      end
      let(:call_args) { { board_id: board.id, value: status.id } }
      let(:expected_filter) { { status_id: { operator: "=", values: [status.id.to_s] } } }
      let(:expected_name) { "In progress" }

      it_behaves_like "a created list"

      it "keeps the board linked to its sprint" do
        mcp_request

        expect(board.reload.linked).to eq(sprint)
        expect(board.options[:filters]).to eq([{ sprint_id: { operator: "=", values: [sprint.id.to_s] } }])
      end
    end

    context "with an assignee board" do
      let(:board) { action_board(Boards::AssigneeBoardCreateService, "assignee") }
      let(:assignee) do
        create(:user, firstname: "Anna", lastname: "Assignee",
                      member_with_permissions: { project => %i[view_work_packages work_package_assigned] })
      end
      let(:call_args) { { board_id: board.id, value: assignee.id } }
      let(:expected_filter) { { assignee: { operator: "=", values: [assignee.id.to_s] } } }
      let(:expected_name) { assignee.name }

      def add_ui_made_list(grid, condition)
        grid.widgets.create!(identifier: "work_package_query",
                             start_row: 1,
                             end_row: 2,
                             start_column: 1,
                             end_column: 2,
                             options: { "queryId" => create(:public_query, project:).id,
                                        "filters" => [{ "assignee" => condition }] })
      end

      it_behaves_like "a created list"

      it "stores the filter name the frontend reads in the widget while the query filters by assigned_to_id" do
        mcp_request

        widget, query = new_list

        expect(widget.options["filters"].sole.keys).to eq([:assignee])
        expect(query.filters.map(&:to_hash)).to eq([{ assigned_to_id: { operator: "=", values: [assignee.id.to_s] } }])
      end

      context "when passing an explicit null value" do
        let(:call_args) { { board_id: board.id, value: nil } }
        let(:expected_filter) { { assignee: { operator: "!*", values: [] } } }
        let(:expected_name) { I18n.t(:label_none) }

        it_behaves_like "a created list"

        it "filters the query for work packages without an assignee" do
          mcp_request

          expect(new_list.last.filters.map(&:to_hash)).to eq([{ assigned_to_id: { operator: "!*", values: [] } }])
        end
      end

      context "when the board already has a list the UI made for the assignee" do
        let(:board) do
          action_board(Boards::AssigneeBoardCreateService, "assignee").tap do |grid|
            add_ui_made_list(grid, { "operator" => "=", "values" => [assignee.id.to_s] })
          end
        end
        let(:expected_error) { "The board already has a list for this value." }

        it_behaves_like "a rejected list"

        context "when asking for the unassigned list" do
          let(:call_args) { { board_id: board.id, value: nil } }
          let(:expected_filter) { { assignee: { operator: "!*", values: [] } } }
          let(:expected_name) { I18n.t(:label_none) }

          it_behaves_like "a created list"
        end
      end

      context "when the board already has the unassigned list" do
        let(:board) do
          action_board(Boards::AssigneeBoardCreateService, "assignee").tap do |grid|
            add_ui_made_list(grid, { "operator" => "!*", "values" => [] })
          end
        end
        let(:call_args) { { board_id: board.id, value: nil } }
        let(:expected_error) { "The board already has a list for this value." }

        it_behaves_like "a rejected list"
      end

      context "when the board already has a list this tool made for the assignee" do
        let(:expected_error) { "The board already has a list for this value." }

        before do
          header "Authorization", "Bearer #{access_token.plaintext_token}"
          header "Content-Type", "application/json"
          post "/mcp", request_body.to_json
        end

        it_behaves_like "a rejected list"
      end

      context "when passing no value at all" do
        let(:call_args) { { board_id: board.id } }
        let(:expected_error) { "Pass a value for the list, or null for the list of unassigned work packages." }

        it_behaves_like "a rejected list"
      end

      context "when the principal is not assignable in the project" do
        let(:call_args) { { board_id: board.id, value: create(:user).id } }
        let(:expected_error) { "The given assignee is not available in this project." }

        it_behaves_like "a rejected list"
      end
    end

    context "with a version board" do
      let!(:existing_version) { create(:version, project:, name: "Sprint 1") }
      let(:version) { create(:version, project:, name: "Sprint 2") }
      let(:board) { action_board(Boards::VersionBoardCreateService, "version") }
      let(:call_args) { { board_id: board.id, value: version.id } }
      let(:expected_filter) { { version_id: { operator: "=", values: [version.id.to_s] } } }
      let(:expected_name) { "Sprint 2" }

      it_behaves_like "a created list"

      context "when multiple versions are enabled", with_settings: { work_package_multiple_versions: true } do
        it_behaves_like "a created list"

        it "keeps the stored version_id key in the widget while the query translates it" do
          mcp_request

          widget = board.reload.widgets.max_by(&:start_column)
          query = Query.find(widget.options["queryId"])

          expect(widget.options["filters"].sole.keys).to eq([:version_id])
          expect(query.filters.map(&:to_hash).sole.keys).to eq([:target_version_id])
        end
      end

      context "when multiple versions are disabled", with_settings: { work_package_multiple_versions: false } do
        it "stores the version_id key in both the widget and the query" do
          mcp_request

          widget = board.reload.widgets.max_by(&:start_column)
          query = Query.find(widget.options["queryId"])

          expect(widget.options["filters"].sole.keys).to eq([:version_id])
          expect(query.filters.map(&:to_hash).sole.keys).to eq([:version_id])
        end
      end

      context "when the board already has a list for the version" do
        let(:call_args) { { board_id: board.id, value: existing_version.id } }
        let(:expected_error) { "The board already has a list for this value." }

        it_behaves_like "a rejected list"
      end

      context "when the version belongs to another project" do
        let(:call_args) { { board_id: board.id, value: create(:version).id } }
        let(:expected_error) { "The given version is not available in this project." }

        it_behaves_like "a rejected list"
      end
    end

    context "with a subproject board" do
      let(:subproject) { create(:project, parent: project, name: "Subproject") }
      let(:board) { action_board(Boards::SubprojectBoardCreateService, "subproject") }
      let(:call_args) { { board_id: board.id, value: subproject.id } }
      let(:expected_filter) { { onlySubproject: { operator: "=", values: [subproject.id.to_s] } } }
      let(:expected_name) { "Subproject" }

      before do
        create(:member,
               principal: user,
               project: subproject,
               roles: [create(:project_role, permissions: %i[view_work_packages])])
      end

      it_behaves_like "a created list"

      it "stores the filter name the frontend reads in the widget while the query filters by only_subproject_id" do
        mcp_request

        widget, query = new_list

        expect(widget.options["filters"].sole.keys).to eq([:onlySubproject])
        expect(query.filters.map(&:to_hash))
          .to eq([{ only_subproject_id: { operator: "=", values: [subproject.id.to_s] } }])
      end

      context "when the board already has a list this tool made for the subproject" do
        let(:expected_error) { "The board already has a list for this value." }

        before do
          header "Authorization", "Bearer #{access_token.plaintext_token}"
          header "Content-Type", "application/json"
          post "/mcp", request_body.to_json
        end

        it_behaves_like "a rejected list"
      end

      context "when the project is visible but not a descendant" do
        let(:other_project) { create(:project) }
        let(:call_args) { { board_id: board.id, value: other_project.id } }
        let(:expected_error) { "The given subproject could not be found." }

        before do
          create(:member,
                 principal: user,
                 project: other_project,
                 roles: [create(:project_role, permissions: %i[view_work_packages])])
        end

        it_behaves_like "a rejected list"
      end

      context "when the subproject is not visible to the user" do
        let(:hidden_subproject) { create(:project, parent: project) }
        let(:call_args) { { board_id: board.id, value: hidden_subproject.id } }
        let(:expected_error) { "The given subproject could not be found." }

        it_behaves_like "a rejected list"
      end
    end

    context "with a parent-child board" do
      let(:epic) { create(:work_package, project:, subject: "Rozszerzenie MCP") }
      let(:board) { action_board(Boards::SubtasksBoardCreateService, "subtasks") }
      let(:call_args) { { board_id: board.id, value: epic.id } }
      let(:expected_filter) { { parent: { operator: "=", values: [epic.id.to_s] } } }
      let(:expected_name) { "Rozszerzenie MCP" }

      it_behaves_like "a created list"

      context "when the work package is visible but belongs to another project" do
        let(:other_project) { create(:project) }
        let(:call_args) { { board_id: board.id, value: create(:work_package, project: other_project).id } }
        let(:expected_error) { "The given work package could not be found in this project." }

        before do
          create(:member,
                 principal: user,
                 project: other_project,
                 roles: [create(:project_role, permissions: %i[view_work_packages])])
        end

        it_behaves_like "a rejected list"
      end

      context "when the work package is in the board project but not visible to the user" do
        let(:permissions) { %i[show_board_views manage_board_views manage_public_queries save_queries] }
        let(:expected_error) { "The given work package could not be found in this project." }

        it_behaves_like "a rejected list"
      end

      context "when the work package belongs to a project the user cannot see" do
        let(:call_args) { { board_id: board.id, value: create(:work_package).id } }
        let(:expected_error) { "The given work package could not be found in this project." }

        it_behaves_like "a rejected list"
      end

      context "when the work package is a milestone" do
        let(:milestone) { create(:work_package, :is_milestone, project:) }
        let(:call_args) { { board_id: board.id, value: milestone.id } }
        let(:expected_error) { "The given work package could not be found in this project." }

        it_behaves_like "a rejected list"
      end
    end

    context "when the user may only view boards" do
      let(:permissions) { %i[view_work_packages show_board_views] }
      let(:expected_error) { "You are not allowed to manage boards in this project." }

      it_behaves_like "a rejected list"
    end

    context "when the board is in a project the user may not see" do
      let(:board) { create(:board_grid, project: create(:project)) }
      let(:expected_error) { "The given board could not be found." }

      it_behaves_like "a rejected list"
    end

    context "when the board does not exist" do
      let(:call_args) { { board_id: board.id + 100 } }
      let(:expected_error) { "The given board could not be found." }

      it_behaves_like "a rejected list"
    end

    context "when the boards module is disabled in the project" do
      let(:project) { create(:project, disable_modules: :board_view) }
      let(:expected_error) { "The given board could not be found." }

      it_behaves_like "a rejected list"
    end
  end

  context "when the MCP server is disabled" do
    let(:server_config) { create(:mcp_configuration, identifier: "mcp_server", enabled: false) }

    it "responds with a 404" do
      mcp_request

      expect(last_response).to have_http_status(404)
    end
  end
end
