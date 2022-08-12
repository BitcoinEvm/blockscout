defmodule BlockScoutWeb.TransactionStateController do
  use BlockScoutWeb, :controller

  alias BlockScoutWeb.{
    AccessHelpers,
    Controller,
    TransactionController
  }

  alias Explorer.{Chain, Market}
  alias Explorer.ExchangeRates.Token

  def index(conn, %{"transaction_id" => transaction_hash_string} = params) do
    with {:ok, transaction_hash} <- Chain.string_to_transaction_hash(transaction_hash_string),
         {:ok, transaction} <-
           Chain.hash_to_transaction(
             transaction_hash,
             necessity_by_association: %{
               [block: :miner] => :required,
               [created_contract_address: :names] => :optional,
               [from_address: :names] => :optional,
               [to_address: :names] => :optional,
               [to_address: :smart_contract] => :optional,
               :token_transfers => :optional
             }
           ),
         {:ok, false} <-
           AccessHelpers.restricted_access?(to_string(transaction.from_address_hash), params),
         {:ok, false} <-
           AccessHelpers.restricted_access?(to_string(transaction.to_address_hash), params) do
      render(
        conn,
        "index.html",
        exchange_rate: Market.get_exchange_rate(Explorer.coin()) || Token.null(),
        block_height: Chain.block_height(),
        current_path: Controller.current_full_path(conn),
        show_token_transfers: Chain.transaction_has_token_transfers?(transaction_hash),
        transaction: transaction
      )
    else
      :not_found ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)

      :error ->
        TransactionController.set_invalid_view(conn, transaction_hash_string)

      {:error, :not_found} ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)

      {:restricted_access, _} ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)
    end
  end
end
