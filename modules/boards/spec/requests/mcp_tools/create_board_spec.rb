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

RSpec.describe McpTools::CreateBoard do
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
        name: "create_board",
        arguments: call_args
      }
    }
  end
  let(:call_args) { { project_id: project.id, name: "My board", type: board_type } }
  let(:board_type) { "basic" }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:result_item) { parsed_results.fetch("structuredContent") }

  let(:project) { create(:project) }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    server_config.save!
    tool_config.save!
  end

  def created_board
    Boards::Grid.last
  end

  context "when the MCP server is enabled" do
    it_behaves_like "MCP text tool"

    shared_examples_for "a created board" do
      it "creates the board in the project" do
        expect { mcp_request }.to change(Boards::Grid, :count).by(1)

        expect(created_board.name).to eq("My board")
        expect(created_board.project).to eq(project)
      end
    end

    shared_examples_for "a board with list queries" do
      it "creates public, manually sorted queries scoped to the project" do
        mcp_request

        queries = created_board.contained_queries
        expect(queries).to be_present
        queries.each do |query|
          expect(query).to be_public
          expect(query.project).to eq(project)
          expect(query.sort_criteria).to eq([%w[manual_sorting asc], %w[id asc]])
        end
      end
    end

    context "with a basic board" do
      it_behaves_like "a created board"
      it_behaves_like "a board with list queries"

      it "creates a free board with a single unnamed list" do
        mcp_request

        expect(created_board.board_type).to eq(:free)
        expect(created_board.board_type_attribute).to be_nil
        expect(created_board.widgets.count).to eq(1)

        query = created_board.contained_queries.sole
        expect(query.name).to eq("Unnamed list")
        expect(query.filters.map(&:name)).to eq([:manual_sort])
      end

      it "responds with the rendered grid" do
        mcp_request

        expect(result_item.fetch("_type")).to eq("Grid")
        expect(result_item.dig("_links", "self", "href")).to eq("/api/v3/grids/#{created_board.id}")
        expect(result_item.dig("options", "type")).to eq("free")
      end
    end

    context "with a status board" do
      let(:board_type) { "status" }
      let!(:default_status) { create(:default_status) }

      it_behaves_like "a created board"
      it_behaves_like "a board with list queries"

      it "creates an action board with a list for the default status" do
        mcp_request

        expect(created_board.board_type).to eq(:action)
        expect(created_board.board_type_attribute).to eq("status")
        expect(created_board.widgets.count).to eq(1)

        query = created_board.contained_queries.sole
        expect(query.name).to eq(default_status.name)
        expect(query.filters.map(&:name)).to eq([:status_id])

        widget = created_board.widgets.sole
        expect(widget.options["filters"])
          .to eq([{ status_id: { operator: "=", values: [default_status.id.to_s] } }])
        expect(widget.options["queryId"]).to eq(query.id)
      end
    end

    context "with a version board" do
      let(:board_type) { "version" }
      let!(:open_versions) { create_list(:version, 2, project:) }
      let!(:closed_version) { create(:version, project:, status: "closed") }

      it_behaves_like "a created board"
      it_behaves_like "a board with list queries"

      it "creates a list per open version" do
        mcp_request

        expect(created_board.board_type_attribute).to eq("version")
        expect(created_board.widgets.count).to eq(2)
        expect(created_board.contained_queries.pluck(:name)).to match_array(open_versions.map(&:name))
      end
    end

    %w[assignee subproject subtasks].each do |type|
      context "with a #{type} board" do
        let(:board_type) { type }

        it_behaves_like "a created board"

        it "creates an empty action board" do
          expect { mcp_request }.not_to change(Query, :count)

          expect(created_board.board_type).to eq(:action)
          expect(created_board.board_type_attribute).to eq(type)
          expect(created_board.widgets).to be_empty
          expect(created_board.contained_queries).to be_empty
        end
      end
    end

    context "when the type is not one of the board types" do
      let(:board_type) { "kanban" }

      it_behaves_like "MCP tool execution error response"

      it "reports the schema violation and creates nothing" do
        expect { mcp_request }.not_to change(Boards::Grid, :count)

        expect(parsed_results.dig("content", 0, "text")).to include("Invalid arguments")
      end
    end

    context "when the project is given by its identifier" do
      let(:call_args) { { project_id: project.identifier, name: "My board", type: "basic" } }

      it "creates the board in the project" do
        expect { mcp_request }.to change(Boards::Grid, :count).by(1)

        expect(created_board.project).to eq(project)
      end
    end

    context "when the project does not exist" do
      let(:call_args) { { project_id: project.id + 100, name: "My board", type: "basic" } }

      it "responds with an error" do
        expect { mcp_request }.not_to change(Boards::Grid, :count)

        expect(result_item.fetch("error")).to eq("The given project could not be found.")
      end
    end

    context "when the user cannot see the project" do
      let(:user) { create(:user) }

      it "responds with an error" do
        expect { mcp_request }.not_to change(Boards::Grid, :count)

        expect(result_item.fetch("error")).to eq("The given project could not be found.")
      end
    end

    context "when the boards module is disabled in the project" do
      let(:project) { create(:project, disable_modules: :board_view) }

      it "responds with an error" do
        expect { mcp_request }.not_to change(Boards::Grid, :count)

        expect(result_item.fetch("error"))
          .to eq("The Boards module is not enabled in this project. Enable it before managing boards.")
      end
    end

    context "when the user may only view boards" do
      let(:permissions) { %i[view_work_packages show_board_views] }

      it "responds with an error and creates nothing" do
        expect { mcp_request }.not_to change(Boards::Grid, :count)
        expect(Query.count).to eq(0)

        expect(result_item.fetch("error")).to eq("You are not allowed to manage boards in this project.")
      end
    end

    context "when the name is blank" do
      let(:call_args) { { project_id: project.id, name: "", type: "basic" } }

      it "responds with an error" do
        expect { mcp_request }.not_to change(Boards::Grid, :count)

        expect(result_item.fetch("error")).to include("Name")
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
