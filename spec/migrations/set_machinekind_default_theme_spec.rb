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
require Rails.root.join("db/migrate/20261004120000_set_machinekind_default_theme.rb")

RSpec.describe SetMachinekindDefaultTheme, type: :model do
  subject(:migrate_up) { ActiveRecord::Migration.suppress_messages { described_class.new.up } }

  let(:upstream_default_colors) do
    {
      "primary-button-color" => "#1F883D",
      "accent-color" => "#1A67A3",
      "header-bg-color" => "#1A67A3",
      "main-menu-bg-color" => "#FFFFFF",
      "main-menu-bg-selected-background" => "#175A8E"
    }
  end

  context "with a style on the old default theme and no color overrides" do
    let!(:custom_style) { create(:custom_style, theme: "OpenProject (default)") }

    it "switches the style to the Machinekind theme and refreshes its cache key" do
      previous_update = custom_style.reload.updated_at

      migrate_up

      expect(custom_style.reload.theme).to eq("Machinekind")
      expect(custom_style.updated_at).not_to eq(previous_update)
    end
  end

  context "with a style on the old default theme and color overrides" do
    let!(:custom_style) { create(:custom_style, theme: "OpenProject (default)") }

    before do
      create(:design_color, variable: "accent-color", hexcode: "#333333")
    end

    it "keeps the old theme" do
      migrate_up

      expect(custom_style.reload.theme).to eq("OpenProject (default)")
    end
  end

  context "with another theme" do
    let!(:custom_style) { create(:custom_style, theme: "OpenProject Gray") }

    it "keeps that theme" do
      migrate_up

      expect(custom_style.reload.theme).to eq("OpenProject Gray")
    end
  end

  context "with a style on the old default theme and exactly the upstream default colors stored" do
    let!(:custom_style) { create(:custom_style, theme: "OpenProject (default)") }

    before do
      upstream_default_colors.each { |variable, hexcode| create(:design_color, variable:, hexcode:) }
    end

    it "removes the stored defaults and switches the style to the Machinekind theme" do
      migrate_up

      expect(DesignColor.count).to eq(0)
      expect(custom_style.reload.theme).to eq("Machinekind")
    end
  end

  context "with the upstream default colors and one changed color" do
    let!(:custom_style) { create(:custom_style, theme: "OpenProject (default)") }

    before do
      colors = upstream_default_colors.merge("accent-color" => "#333333")
      colors.each { |variable, hexcode| create(:design_color, variable:, hexcode:) }
    end

    it "keeps the colors and the old theme" do
      migrate_up

      expect(DesignColor.count).to eq(5)
      expect(custom_style.reload.theme).to eq("OpenProject (default)")
    end
  end

  describe "theme column default" do
    def change_theme_default(theme)
      ActiveRecord::Base.connection.change_column_default(:custom_styles, :theme, theme)
      CustomStyle.reset_column_information
    end

    after do
      change_theme_default("Machinekind")
    end

    it "changes from the old default theme to Machinekind" do
      change_theme_default("OpenProject (default)")
      expect(CustomStyle.new.theme).to eq("OpenProject (default)")

      migrate_up
      CustomStyle.reset_column_information

      expect(CustomStyle.new.theme).to eq("Machinekind")
    end

    it "reverts to the old default theme on rollback and renames Machinekind styles" do
      custom_style = create(:custom_style, theme: "Machinekind")

      ActiveRecord::Migration.suppress_messages { described_class.new.down }
      CustomStyle.reset_column_information

      expect(CustomStyle.new.theme).to eq("OpenProject (default)")
      expect(custom_style.reload.theme).to eq("OpenProject (default)")
    end
  end
end
