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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "spec_helper"

RSpec.describe OpenProject::RateLimiting::InviteLinkJoin do
  subject(:rule) { described_class.new }

  def request_for(path, method: "GET")
    Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method:).merge("REMOTE_ADDR" => "10.0.0.1"))
  end

  it "is enabled by default" do
    expect(described_class).to be_enabled
  end

  it "uses its own bucket" do
    expect(described_class.rule_name).to eq "invite_link_join"
  end

  it "throttles the join route per client IP" do
    expect(rule.send(:discriminator, request_for("/account/join/join-abc"))).to eq "10.0.0.1"
    expect(rule.send(:discriminator, request_for("/account/join/join-abc", method: "POST"))).to eq "10.0.0.1"
  end

  it "ignores other routes" do
    expect(rule.send(:discriminator, request_for("/account/register", method: "POST"))).to be_nil
  end

  it "defaults to 20 requests per 10 minutes" do
    expect(rule.send(:limit)).to eq 20
    expect(rule.send(:period)).to eq 600
  end
end
