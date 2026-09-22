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

RSpec.describe McpTools::SearchBoards do
  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) { create(:oauth_access_token, scopes: "mcp", resource_owner: user) }
  let(:user) { create(:user, member_with_permissions: { project => permissions }) }
  let(:permissions) { %i[view_work_packages show_board_views] }
  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: {
        name: "search_boards",
        arguments: call_args
      }
    }
  end
  let(:call_args) { {} }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:items) { parsed_results.dig("structuredContent", "items") }

  let(:project) { create(:project) }
  let(:other_project) { create(:project) }

  let!(:board) { create(:board_grid_with_query, project:, name: "O'Brien's board") }
  let!(:other_board) { create(:board_grid, project:, name: "Delivery board") }
  let!(:invisible_board) { create(:board_grid, project: other_project, name: "Secret board") }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    server_config.save!
    tool_config.save!
  end

  context "when the MCP server is enabled" do
    it_behaves_like "MCP text tool"

    it "finds only the boards of projects the user may see boards in" do
      mcp_request

      expect(items.pluck("name")).to contain_exactly("O'Brien's board", "Delivery board")
    end

    it "renders each board as a grid with its options and lists" do
      mcp_request

      item = items.find { |board_item| board_item["name"] == "O'Brien's board" }
      widget = item.fetch("widgets").sole

      expect(item.fetch("_type")).to eq("Grid")
      expect(item.fetch("options")).to eq({})
      expect(widget.dig("options", "queryId")).to eq(board.widgets.sole.options["queryId"])
      expect(widget.dig("options", "filters")).to eq([{ "manualSort" => { "operator" => "ow", "values" => [] } }])
    end

    context "when filtering by project" do
      let(:call_args) { { project_id: other_project.id } }
      let(:user) do
        create(:user, member_with_permissions: { project => permissions, other_project => permissions })
      end

      it "returns only the boards of that project" do
        mcp_request

        expect(items.pluck("name")).to eq(["Secret board"])
      end
    end

    context "when filtering by id" do
      let(:call_args) { { id: other_board.id } }

      it "returns only that board" do
        mcp_request

        expect(items.pluck("name")).to eq(["Delivery board"])
      end
    end

    context "when filtering by a partial name in a different case" do
      let(:call_args) { { name: "deLIVery" } }

      it "returns the matching board" do
        mcp_request

        expect(items.pluck("name")).to eq(["Delivery board"])
      end
    end

    context "when filtering by a name containing an apostrophe" do
      let(:call_args) { { name: "O'Brien" } }

      it "returns the matching board" do
        mcp_request

        expect(items.pluck("name")).to eq(["O'Brien's board"])
      end
    end

    context "with a board linked to a sprint" do
      let(:sprint) { create(:sprint, project:) }
      let!(:sprint_board) do
        create(:board_grid,
               project:,
               name: "Task board",
               linked: sprint,
               options: { type: "action",
                          attribute: "status",
                          filters: [{ sprint_id: { operator: "=", values: [sprint.id.to_s] } }] })
      end

      let(:call_args) { { id: sprint_board.id } }

      it "returns the board with its persisted filters readable" do
        mcp_request

        item = items.sole
        expect(item.dig("options", "attribute")).to eq("status")
        expect(item.dig("options", "filters"))
          .to eq([{ "sprint_id" => { "operator" => "=", "values" => [sprint.id.to_s] } }])
      end
    end

    context "when the user is a member of no project" do
      let(:user) { create(:user) }

      it "returns no boards" do
        mcp_request

        expect(items).to be_empty
        expect(parsed_results.dig("structuredContent", "total")).to eq(0)
      end
    end

    describe "pagination" do
      let(:page_size) { 3 }
      let(:overspilling_boards) { 2 }
      let(:call_args) { { name: "Paged" } }

      before do
        allow(described_class).to receive(:page_size).and_return(page_size)

        (page_size + overspilling_boards).times do |idx|
          create(:board_grid, project:, name: "Paged board #{idx}")
        end
      end

      def page(number)
        header "Authorization", "Bearer #{access_token.plaintext_token}"
        header "Content-Type", "application/json"
        post "/mcp", request_body.merge(params: { name: "search_boards",
                                                  arguments: { name: "Paged", page: number } }).to_json

        JSON.parse(last_response.body).dig("result", "structuredContent", "items").pluck("id")
      end

      it "returns only results up to the page size" do
        mcp_request

        expect(items.count).to eq(page_size)
        expect(parsed_results.dig("structuredContent", "total")).to eq(page_size + overspilling_boards)
      end

      it "splits the boards over the pages in id order" do
        first_page = page(1)
        second_page = page(2)

        expect(first_page).to eq(first_page.sort)
        expect(second_page).to eq(second_page.sort)
        expect(first_page & second_page).to be_empty
        expect(first_page.last).to be < second_page.first
      end

      context "when another page is requested" do
        let(:call_args) { { name: "Paged", page: 2 } }

        it "returns the requested page" do
          mcp_request

          expect(items.count).to eq(overspilling_boards)
        end
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
