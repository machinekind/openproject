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

require "spec_helper"

RSpec.describe McpTools::CreateUser do
  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) { create(:oauth_access_token, scopes: "mcp", resource_owner: user) }
  let(:user) { create(:admin) }
  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: {
        name: "create_user",
        arguments: call_args
      }
    }
  end
  let(:call_args) do
    {
      data: {
        login: "wojtek",
        email: "wojtek@example.com",
        firstName: "Wojtek",
        lastName: "Bear",
        status: "invited"
      }
    }
  end
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:result_item) { parsed_results.fetch("structuredContent") }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    server_config.save!
    tool_config.save!
  end

  context "when the mcp_server enterprise feature is enabled", with_ee: %i[mcp_server] do
    it_behaves_like "MCP text tool"

    it "creates a new invited user" do
      expect { mcp_request }.to change { User.find_by(login: "wojtek") }.from(nil)

      created = User.find_by(login: "wojtek")
      expect(created.mail).to eq("wojtek@example.com")
      expect(created.firstname).to eq("Wojtek")
      expect(created.lastname).to eq("Bear")
      expect(created).to be_invited
    end

    it "responds with a properly formatted user" do
      mcp_request

      expect(result_item.to_json).to match_json_schema.from_docs("user_model")
    end

    context "when the email is missing" do
      let(:call_args) { { data: { login: "wojtek", firstName: "Wojtek", lastName: "Bear", status: "invited" } } }

      it "responds with an error" do
        mcp_request
        expect(result_item.fetch("error")).to include("Email can't be blank")
      end

      it "does not create a user" do
        mcp_request
        expect(User.find_by(login: "wojtek")).to be_nil
      end
    end
  end

  context "when the mcp_server enterprise feature is disabled" do
    it "responds with a 404" do
      mcp_request
      expect(last_response).to have_http_status(404)
    end
  end
end
