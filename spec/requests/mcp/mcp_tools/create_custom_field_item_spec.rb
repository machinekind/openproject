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

require "spec_helper"

RSpec.describe McpTools::CreateCustomFieldItem do
  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) do
    create(:oauth_access_token, scopes: "mcp", resource_owner: user, application: create(:oauth_application, owner: nil))
  end
  let(:user) { create(:admin) }
  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: {
        name: "create_custom_field_item",
        arguments: call_args
      }
    }
  end
  let(:call_args) { { custom_field_id: custom_field.id, label: "Europe" } }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:result_item) { parsed_results.fetch("structuredContent") }

  let!(:custom_field) { create(:wp_custom_field, :hierarchy) }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    server_config.save!
    tool_config.save!
    access_token
  end

  context "when the MCP server is enabled" do
    it_behaves_like "MCP text tool"

    it "adds the item below the root" do
      expect { mcp_request }.to change { custom_field.hierarchy_root.reload.children.count }.from(0).to(1)

      expect(custom_field.hierarchy_root.children.first.label).to eq("Europe")
      expect(result_item).to include("label" => "Europe")
    end

    it "responds with a properly formatted item" do
      mcp_request

      expect(result_item.to_json).to match_json_schema.from_docs("hierarchy_item_read_model")
    end

    context "when giving a short name" do
      let(:call_args) { { custom_field_id: custom_field.id, label: "Europe", short: "EU" } }

      it "stores it" do
        mcp_request

        expect(custom_field.hierarchy_root.reload.children.first.short).to eq("EU")
      end
    end

    context "when giving a parent item" do
      let(:europe) do
        CustomFields::Hierarchy::HierarchicalItemService.new
          .insert_item(contract_class: CustomFields::Hierarchy::InsertListItemContract,
                       parent: custom_field.hierarchy_root, label: "Europe")
          .value!
      end
      let(:call_args) { { custom_field_id: custom_field.id, label: "Poland", parent_item_id: europe.id } }

      it "adds the item below the parent" do
        mcp_request

        expect(europe.reload.children.pluck(:label)).to eq(["Poland"])
      end
    end

    context "when the label already exists among the siblings" do
      before do
        CustomFields::Hierarchy::HierarchicalItemService.new
          .insert_item(contract_class: CustomFields::Hierarchy::InsertListItemContract,
                       parent: custom_field.hierarchy_root, label: "Europe")
      end

      it "responds with a readable error" do
        expect { mcp_request }.not_to change(CustomField::Hierarchy::Item, :count)

        expect(result_item.fetch("error")).to start_with("label:")
      end
    end

    context "when the custom field is a list" do
      let!(:custom_field) { create(:wp_custom_field, :list) }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("Items can only be added to hierarchy custom fields.")
      end
    end

    context "when the custom field does not exist" do
      let(:call_args) { { custom_field_id: custom_field.id + 100, label: "Europe" } }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("The given custom field could not be found.")
      end
    end

    context "when the parent belongs to another custom field" do
      let!(:other_field) { create(:wp_custom_field, :hierarchy) }
      let(:call_args) { { custom_field_id: custom_field.id, label: "Europe", parent_item_id: other_field.hierarchy_root.id } }

      it "responds with an error and adds nothing" do
        expect { mcp_request }.not_to change(CustomField::Hierarchy::Item, :count)

        expect(result_item.fetch("error")).to eq("The given parent item does not belong to this custom field.")
      end
    end

    context "when the user is not an administrator" do
      let(:user) { create(:user) }

      it "responds with an error and adds nothing" do
        expect { mcp_request }.not_to change(CustomField::Hierarchy::Item, :count)

        expect(result_item.fetch("error")).to eq("Only administrators can change custom field items.")
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
