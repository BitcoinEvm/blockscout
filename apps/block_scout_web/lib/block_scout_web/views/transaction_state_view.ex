defmodule BlockScoutWeb.TransactionStateView do
  use BlockScoutWeb, :view

  alias Explorer.Chain
  alias Explorer.Chain.Wei

  def coin_balance_or_zero(address_hash, block_number) do
    case Chain.get_coin_balance(address_hash, block_number) do
      %{value: val} when not is_nil(val) -> val
      _ -> %Wei{value: Decimal.new(0)}
    end
  end

  def balances_before(tx) do
    block = tx.block

    from_before = coin_balance_or_zero(tx.from_address_hash, block.number - 1)
    to_before = coin_balance_or_zero(tx.to_address_hash, block.number - 1)
    miner_before = coin_balance_or_zero(block.miner_hash, block.number - 1)

    Chain.block_to_transactions(
      block.hash,
      [{:necessity_by_association, %{:block => :required}}]
    )
    |> Enum.reduce_while(
      {from_before, to_before, miner_before},
      fn block_tx, {block_from, block_to, block_miner} = state ->
        # if is_nil(block_tx.index) maybe worth cheching if its nil
        if block_tx.index < tx.index do
          {:cont,
           {do_state_update(tx.from_address_hash, block_tx, block_from),
            do_state_update(tx.to_address_hash, block_tx, block_to),
            do_state_update(tx.block.miner_hash, block_tx, block_miner)}}
        else
          # txs ordered by index ascending, so we can halt after facing index greater or equal than index of our tx
          {:halt, state}
        end
      end
    )
  end

  defp do_state_update(address_hash, block_tx, balance) do
    from = block_tx.from_address_hash
    to = block_tx.to_address_hash
    miner = block_tx.block.miner_hash

    case address_hash do
      ^from -> Wei.sub(balance, from_loss(block_tx))
      ^to -> Wei.sum(balance, to_profit(block_tx))
      ^miner -> Wei.sum(balance, miner_profit(block_tx))
      _ -> balance
    end
  end

  def from_loss(tx) do
    {_, fee} = Chain.fee(tx, :wei)
    fee = %Wei{value: fee}
    Wei.sum(tx.value, fee)
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

  def display_to?(tx) do
    case Chain.transaction_to_status(tx) do
      {:error, _} -> false
      _ -> true
    end
  end

  def has_diff?(%Wei{value: val}) do
    Decimal.gt?(val, Decimal.new(0))
  end
end
