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

RSpec.describe McpTools::UpdateBoard do
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
        name: "update_board",
        arguments: call_args
      }
    }
  end
  let(:call_args) { { id: board.id, filters: epic_filter } }
  let(:epic_filter) { [{ type: { operator: "=", values: [type.id.to_s] } }] }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:result_item) { parsed_results.fetch("structuredContent") }

  let(:type) { create(:type, name: "Epic") }
  let(:stored_epic_filter) { [{ type: { operator: "=", values: [type.id.to_s] } }] }
  let(:project) { create(:project, types: [type]) }
  let(:board) { create(:board_grid, project:) }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    server_config.save!
    tool_config.save!
  end

  shared_examples_for "a rejected update" do
    it "responds with an error and leaves the board alone" do
      options_before = board.options
      name_before = board.name

      mcp_request

      expect(board.reload.options).to eq(options_before)
      expect(board.name).to eq(name_before)
      expect(result_item.fetch("error")).to include(expected_error)
    end
  end

  context "when the MCP server is enabled" do
    it_behaves_like "MCP text tool"

    it "persists the filters in the normalised APIv3 form" do
      mcp_request

      expect(board.reload.options[:filters]).to eq(stored_epic_filter)
      expect(result_item.dig("options", "filters"))
        .to eq([{ "type" => { "operator" => "=", "values" => [type.id.to_s] } }])
    end

    context "with a board that has lists" do
      let(:board) do
        User.execute_as(user) do
          Boards::BasicBoardCreateService.new(user:).call(project:, name: "My board", attribute: "basic").result
        end
      end

      it "leaves the lists of the board untouched" do
        widget = board.widgets.sole

        mcp_request

        expect(board.reload.widgets.map(&:id)).to eq([widget.id])
        expect(board.widgets.sole.options).to eq(widget.options)
        expect(board.column_count).to eq(4)
      end
    end

    context "when passing an empty filter array" do
      let(:board) { create(:board_grid, project:, options: { "filters" => [{ "type" => { "operator" => "=" } }] }) }
      let(:call_args) { { id: board.id, filters: [] } }

      it "removes all filters" do
        mcp_request

        expect(board.reload.options[:filters]).to eq([])
      end
    end

    context "with an action board" do
      let(:board) do
        create(:board_grid, project:, options: { "type" => "action", "attribute" => "status" })
      end

      it "keeps the board type and stores the filters under a single key" do
        mcp_request

        options = board.reload.options
        expect(options[:type]).to eq("action")
        expect(options[:attribute]).to eq("status")
        expect(options.keys.map(&:to_s).count("filters")).to eq(1)
      end
    end

    context "when passing a name only" do
      let(:call_args) { { id: board.id, name: "Renamed board" } }

      it "renames the board without touching its options" do
        options_before = board.options

        mcp_request

        expect(board.reload.name).to eq("Renamed board")
        expect(board.options).to eq(options_before)
      end
    end

    context "when passing a name and filters" do
      let(:call_args) { { id: board.id, name: "Renamed board", filters: epic_filter } }

      it "applies both" do
        mcp_request

        expect(board.reload.name).to eq("Renamed board")
        expect(board.options[:filters]).to eq(stored_epic_filter)
      end
    end

    context "when passing neither a name nor filters" do
      let(:call_args) { { id: board.id } }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("Pass a name, filters or both.")
      end
    end

    context "when passing an unknown filter" do
      let(:call_args) { { id: board.id, filters: [{ bogus: { operator: "=", values: ["1"] } }] } }
      let(:expected_error) { "filter does not exist" }

      it_behaves_like "a rejected update"
    end

    context "when passing an unsupported operator" do
      let(:call_args) { { id: board.id, filters: [{ type: { operator: "~", values: [type.id.to_s] } }] } }
      let(:expected_error) { "Operator is not set to one of the allowed values" }

      it_behaves_like "a rejected update"
    end

    context "when passing a value that is not available in the project" do
      let(:call_args) { { id: board.id, filters: [{ type: { operator: "=", values: [create(:type).id.to_s] } }] } }
      let(:expected_error) { "Type filter has invalid values." }

      it_behaves_like "a rejected update"
    end

    describe "malformed filters" do
      let(:expected_error) { 'Each filter must be an object like { "type": { "operator": "=", "values": ["5"] } }.' }

      context "when a filter names no attribute" do
        let(:call_args) { { id: board.id, filters: [{}] } }

        it_behaves_like "a rejected update"
      end

      context "when a filter holds an array instead of a condition" do
        let(:call_args) { { id: board.id, filters: [{ status: ["5"] }] } }

        it_behaves_like "a rejected update"
      end

      context "when a filter names two attributes" do
        let(:call_args) do
          { id: board.id,
            filters: [{ status: { operator: "=", values: ["5"] }, type: { operator: "=", values: ["5"] } }] }
        end

        it_behaves_like "a rejected update"
      end
    end

    describe "a filter on the attribute the board's lists are built on" do
      let(:status) { create(:status) }
      let(:version) { create(:version, project:) }
      let(:board) do
        create(:board_grid, project:, options: { "type" => "action", "attribute" => attribute })
      end

      context "with a status board" do
        let(:attribute) { "status" }
        let(:call_args) { { id: board.id, filters: [{ status: { operator: "=", values: [status.id.to_s] } }] } }
        let(:expected_error) { "A status board filters its lists by status; add or remove lists instead." }

        it_behaves_like "a rejected update"
      end

      context "with an assignee board" do
        let(:attribute) { "assignee" }
        let(:assignee) do
          create(:user, member_with_permissions: { project => %i[view_work_packages work_package_assigned] })
        end
        let(:call_args) { { id: board.id, filters: [{ assignee: { operator: "=", values: [assignee.id.to_s] } }] } }
        let(:expected_error) { "An assignee board filters its lists by assignee; add or remove lists instead." }

        it_behaves_like "a rejected update"
      end

      context "with a version board" do
        let(:attribute) { "version" }
        let(:call_args) { { id: board.id, filters: [{ version: { operator: "=", values: [version.id.to_s] } }] } }
        let(:expected_error) { "A version board filters its lists by version; add or remove lists instead." }

        it_behaves_like "a rejected update"
      end

      context "with a basic board" do
        let(:board) { create(:board_grid, project:) }
        let(:call_args) { { id: board.id, filters: [{ status: { operator: "=", values: [status.id.to_s] } }] } }

        it "applies the filter" do
          mcp_request

          expect(board.reload.options[:filters])
            .to eq([{ status: { operator: "=", values: [status.id.to_s] } }])
        end
      end
    end

    context "with a board linked to a sprint" do
      let(:sprint) { create(:sprint, project:) }
      let(:sprint_filter) { [{ sprint_id: { operator: "=", values: [sprint.id.to_s] } }] }
      let(:board) do
        create(:board_grid,
               project:,
               name: "Task board",
               linked: sprint,
               options: { type: "action", attribute: "status", filters: sprint_filter })
      end

      it "refuses to replace its filters" do
        mcp_request

        expect(board.reload.options[:filters]).to eq(sprint_filter)
        expect(result_item.fetch("error"))
          .to eq("This board is managed by the backlogs module and its filters cannot be changed here.")
      end

      context "when passing a name only" do
        let(:call_args) { { id: board.id, name: "Renamed task board" } }

        it "renames the board and keeps the sprint filter" do
          mcp_request

          expect(board.reload.name).to eq("Renamed task board")
          expect(board.options[:filters]).to eq(sprint_filter)
        end
      end
    end

    context "when the user may only view boards" do
      let(:permissions) { %i[view_work_packages show_board_views] }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("You are not allowed to manage boards in this project.")
      end
    end

    context "when the board is in a project the user may not see" do
      let(:board) { create(:board_grid, project: create(:project)) }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("The given board could not be found.")
      end
    end

    context "when the board does not exist" do
      let(:call_args) { { id: board.id + 100, filters: epic_filter } }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("The given board could not be found.")
      end
    end

    context "when the boards module is disabled in the project" do
      let(:project) { create(:project, types: [type], disable_modules: :board_view) }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("The given board could not be found.")
      end
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
