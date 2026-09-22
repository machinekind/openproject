# frozen_string_literal: true

class AddIndexToTokensValue < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :tokens, :value,
              name: :index_tokens_on_value,
              algorithm: :concurrently,
              if_not_exists: true
  end
end
