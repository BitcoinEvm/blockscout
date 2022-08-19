defmodule BlockScoutWeb.TransactionStateController do
  use BlockScoutWeb, :controller

  alias BlockScoutWeb.{
    AccessHelpers,
    Controller,
    TransactionController,
    TransactionStateView
  }

  alias Explorer.{Chain, Chain.Wei, Market, PagingOptions}
  alias Explorer.ExchangeRates.Token
  alias Phoenix.View
  alias Indexer.Fetcher.{TokenBalance, CoinBalance}

  {:ok, burn_address_hash} = Chain.string_to_address_hash("0x0000000000000000000000000000000000000000")

  @burn_address_hash burn_address_hash

  def index(conn, %{"transaction_id" => transaction_hash_string, "type" => "JSON"} = params) do
    with {:ok, transaction_hash} <- Chain.string_to_transaction_hash(transaction_hash_string),
         :ok <- Chain.check_transaction_exists(transaction_hash),
         {:ok, transaction} <-
           Chain.hash_to_transaction(
             transaction_hash,
             necessity_by_association: %{
               [block: :miner] => :required,
               from_address: :required,
               to_address: :required
             }
           ),
         {:ok, false} <-
           AccessHelpers.restricted_access?(to_string(transaction.from_address_hash), params),
         {:ok, false} <-
           AccessHelpers.restricted_access?(to_string(transaction.to_address_hash), params) do
      full_options = [
        necessity_by_association: %{
          [from_address: :smart_contract] => :optional,
          [to_address: :smart_contract] => :optional,
          [from_address: :names] => :optional,
          [to_address: :names] => :optional,
          from_address: :required,
          to_address: :required,
          token: :required
        },
        # we need to consider all token transfers in block to show whole state change of transaction
        paging_options: %PagingOptions{key: nil, page_size: 512}
      ]

      token_transfers = Chain.transaction_to_token_transfers(transaction_hash, full_options)

      block = transaction.block
      {from_before, to_before, miner_before} = coin_balances_before(transaction)

      from_hash = transaction.from_address_hash
      from = transaction.from_address
      from_after = do_update_coin_balance_from_tx(from_hash, transaction, from_before)

      from_coin_entry =
        View.render_to_string(
          TransactionStateView,
          "_state_change.html",
          coin_or_token_transfers: :coin,
          address: from,
          burn_address_hash: @burn_address_hash,
          balance_before: from_before,
          balance_after: from_after,
          balance_diff: Wei.sub(from_after, from_before),
          conn: conn
        )

      to_hash = transaction.to_address_hash
      to = transaction.to_address
      to_after = do_update_coin_balance_from_tx(to_hash, transaction, to_before)

      to_coin_entry =
        View.render_to_string(
          TransactionStateView,
          "_state_change.html",
          coin_or_token_transfers: :coin,
          address: to,
          burn_address_hash: @burn_address_hash,
          balance_before: to_before,
          balance_after: to_after,
          balance_diff: Wei.sub(to_after, to_before),
          conn: conn
        )

      miner_hash = block.miner_hash
      miner = block.miner
      miner_after = do_update_coin_balance_from_tx(miner_hash, transaction, miner_before)

      miner_entry =
        View.render_to_string(
          TransactionStateView,
          "_state_change.html",
          coin_or_token_transfers: :coin,
          address: miner,
          burn_address_hash: @burn_address_hash,
          balance_before: miner_before,
          balance_after: miner_after,
          balance_diff: Wei.sub(miner_after, miner_before),
          miner: true,
          conn: conn
        )

      token_balances_before = token_balances_before(token_transfers, transaction)

      token_balances_after =
        do_update_token_balances_from_token_transfers(
          token_transfers,
          token_balances_before,
          :include_transfers
        )

      items =
        Enum.flat_map(token_balances_after, fn {address, balances} ->
          Enum.map(balances, fn {token_hash, {balance, transfers}} ->
            balance_before = token_balances_before[address][token_hash]

            View.render_to_string(
              TransactionStateView,
              "_state_change.html",
              coin_or_token_transfers: transfers,
              address: address,
              burn_address_hash: @burn_address_hash,
              balance_before: balance_before,
              balance_after: balance,
              balance_diff: Decimal.sub(balance, balance_before),
              conn: conn
            )
          end)
        end)

      json(conn, %{items: [from_coin_entry, to_coin_entry, miner_entry | items]})
    else
      {:restricted_access, _} ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)

      :error ->
        TransactionController.set_invalid_view(conn, transaction_hash_string)

      {:error, :not_found} ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)

      :not_found ->
        TransactionController.set_not_found_view(conn, transaction_hash_string)
    end
  end

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

  def coin_balance_or_zero(address_hash, _block_number) when is_nil(address_hash) do
    %Wei{value: Decimal.new(0)}
  end

  def coin_balance_or_zero(address_hash, block_number) do
    case Chain.get_coin_balance(address_hash, block_number) do
      %{value: val} when not is_nil(val) ->
        val

      _ ->
        json_rpc_named_arguments = Application.get_env(:explorer, :json_rpc_named_arguments)
        CoinBalance.run([{address_hash.bytes, block_number}], json_rpc_named_arguments)
        coin_balance_or_zero(address_hash, block_number)
    end
  end

  def coin_balances_before(tx) do
    block = tx.block

    from_before = coin_balance_or_zero(tx.from_address_hash, block.number - 1)

    to_before = coin_balance_or_zero(tx.to_address_hash, block.number - 1)

    miner_before = coin_balance_or_zero(block.miner_hash, block.number - 1)

    Chain.block_to_transactions(
      block.hash,
      [
        {:necessity_by_association, %{:block => :required}},
        # we need to consider all transactions before our in block or we would get wrong results
        {:paging_options, %PagingOptions{key: nil, page_size: 1024}}
      ]
    )
    |> Enum.reduce_while(
      {from_before, to_before, miner_before},
      fn block_tx, {block_from, block_to, block_miner} = state ->
        # if is_nil(block_tx.index) maybe worth cheching if its nil
        if block_tx.index < tx.index do
          {:cont,
           {do_update_coin_balance_from_tx(tx.from_address_hash, block_tx, block_from),
            do_update_coin_balance_from_tx(tx.to_address_hash, block_tx, block_to),
            do_update_coin_balance_from_tx(tx.block.miner_hash, block_tx, block_miner)}}
        else
          # txs ordered by index ascending, so we can halt after facing index greater or equal than index of our tx
          {:halt, state}
        end
      end
    )
  end

  defp do_update_coin_balance_from_tx(address_hash, tx, balance) do
    from = tx.from_address_hash
    to = tx.to_address_hash
    miner = tx.block.miner_hash

    case address_hash do
      ^from -> Wei.sub(balance, from_loss(tx))
      ^to -> Wei.sum(balance, to_profit(tx))
      ^miner -> Wei.sum(balance, miner_profit(tx))
      _ -> balance
    end
  end

  def token_balance_or_zero(address_hash, token_transfer, block_number) do
    token = token_transfer.token
    token_contract_address_hash = token.contract_address_hash

    case Chain.get_token_balance(address_hash, token_contract_address_hash, block_number) do
      %{value: val} when not is_nil(val) ->
        val

      # we haven't fetched this balance yet
      _ ->
        json_rpc_named_arguments = Application.get_env(:explorer, :json_rpc_named_arguments)

        token_id_int =
          case token_transfer.token_id do
            %Decimal{} -> Decimal.to_integer(token_transfer.token_id)
            id_int when is_integer(id_int) -> id_int
            _ -> token_transfer.token_id
          end

        TokenBalance.run(
          [{address_hash.bytes, token_contract_address_hash.bytes, block_number, token.type, token_id_int, 0}],
          json_rpc_named_arguments
        )

        # after run balance is fetched, so we can call this function again
        token_balance_or_zero(address_hash, token_transfer, block_number)
    end
  end

  def token_balances_before(token_transfers, tx) do
    balances_before =
      token_transfers
      |> Enum.reduce(%{}, fn transfer, balances_map ->
        from = transfer.from_address
        to = transfer.to_address
        token = transfer.token_contract_address_hash
        prev_block = transfer.block_number - 1

        balances_with_from =
          case balances_map do
            # from address already in the map
            %{^from => %{^token => _}} ->
              balances_map

            # we need to add from address into the map
            _ ->
              put_in(
                balances_map,
                Enum.map([from, token], &Access.key(&1, %{})),
                token_balance_or_zero(from.hash, transfer, prev_block)
              )
          end

        case balances_with_from do
          # to address already in the map
          %{^to => %{^token => _}} ->
            balances_with_from

          # we need to add to address into the map
          _ ->
            put_in(
              balances_with_from,
              Enum.map([to, token], &Access.key(&1, %{})),
              token_balance_or_zero(to.hash, transfer, prev_block)
            )
        end
      end)

    Chain.block_to_transactions(tx.block_hash, [
      # we need to consider all transactions before our in block or we would get wrong results
      {:paging_options, %PagingOptions{key: nil, page_size: 1024}}
    ])
    |> Enum.reduce_while(
      balances_before,
      fn block_tx, state ->
        if block_tx.index < tx.index do
          block_token_transfers = Chain.transaction_to_token_transfers(block_tx.hash)
          {:cont, do_update_token_balances_from_token_transfers(block_token_transfers, state)}
        else
          # txs ordered by index ascending, so we can halt after facing index greater or equal than index of our tx
          {:halt, state}
        end
      end
    )
  end

  defp do_update_token_balances_from_token_transfers(
         token_transfers,
         balances_map,
         include_transfers \\ :no
       ) do
    Enum.reduce(token_transfers, balances_map, fn transfer, state_balances_map ->
      from = transfer.from_address
      to = transfer.to_address
      token = transfer.token_contract_address_hash
      transfer_amount = if is_nil(transfer.amount), do: 1, else: transfer.amount

      # point of this function is to include all necessary information for frontend if option :include_transfer is passed
      do_update_balance = fn old_val, type ->
        case {include_transfers, old_val, type} do
          {:include_transfers, {val, transfers}, :from} ->
            {Decimal.sub(val, transfer_amount), [{type, transfer} | transfers]}

          {:include_transfers, {val, transfers}, :to} ->
            {Decimal.add(val, transfer_amount), [{type, transfer} | transfers]}

          {:include_transfers, val, :from} ->
            {Decimal.sub(val, transfer_amount), [{type, transfer}]}

          {:include_transfers, val, :to} ->
            {Decimal.add(val, transfer_amount), [{type, transfer}]}

          {_, val, :from} ->
            Decimal.sub(val, transfer_amount)

          {_, val, :to} ->
            Decimal.add(val, transfer_amount)
        end
      end

      balances_map_from_included =
        case state_balances_map do
          # from address is needed to be updated in our map
          %{^from => %{^token => from_val}} ->
            put_in(
              state_balances_map,
              Enum.map([from, token], &Access.key(&1, %{})),
              do_update_balance.(from_val, :from)
            )

          # we are not interested in this address
          _ ->
            state_balances_map
        end

      case balances_map_from_included do
        # to address is needed to be updated in our map
        %{^to => %{^token => val}} ->
          put_in(
            balances_map_from_included,
            Enum.map([to, token], &Access.key(&1, %{})),
            do_update_balance.(val, :to)
          )

        # we are not interested in this address
        _ ->
          balances_map_from_included
      end
    end)
  end

  def from_loss(tx) do
    {_, fee} = Chain.fee(tx, :wei)
    Wei.sum(tx.value, %Wei{value: fee})
  end

  def to_profit(tx) do
    tx.value
  end

  def miner_profit(tx) do
    base_fee_per_gas = if tx.block, do: tx.block.base_fee_per_gas, else: nil
    max_priority_fee_per_gas = tx.max_priority_fee_per_gas
    max_fee_per_gas = tx.max_fee_per_gas

    priority_fee_per_gas =
      if is_nil(max_priority_fee_per_gas) or is_nil(base_fee_per_gas),
        do: nil,
        else:
          Enum.min_by(
            [max_priority_fee_per_gas, Wei.sub(max_fee_per_gas, base_fee_per_gas)],
            fn x ->
              Wei.to(x, :wei)
            end
          )

    if is_nil(priority_fee_per_gas),
      do: %Wei{value: Decimal.new(0)},
      else: Wei.mult(priority_fee_per_gas, tx.gas_used)
  end
end
