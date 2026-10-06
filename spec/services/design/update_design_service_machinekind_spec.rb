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

RSpec.describe Design::UpdateDesignService do
  let!(:custom_style) { create(:custom_style, theme: nil) }

  before do
    create(:design_color, variable: "accent-color", hexcode: "#333333")
  end

  context "with the Machinekind theme" do
    subject(:result) { described_class.new(OpenProject::Machinekind::Brand.theme).call }

    it "selects the theme and removes all color overrides" do
      expect(result).to be_success
      expect(DesignColor.count).to eq(0)
      expect(custom_style.reload.theme).to eq("Machinekind")
      expect(custom_style.theme_logo).to be_nil
    end
  end

  context "with another predefined theme" do
    subject(:result) { described_class.new(gray_theme).call }

    let(:gray_theme) { OpenProject::CustomStyles::ColorThemes.themes.find { |theme| theme[:theme] == "OpenProject Gray" } }

    it "stores the colors of that theme" do
      expect(result).to be_success
      expect(DesignColor.pluck(:variable)).to match_array(OpenProject::CustomStyles::Design.customizable_variables)
      expect(custom_style.reload.theme).to eq("OpenProject Gray")
    end
  end
end
