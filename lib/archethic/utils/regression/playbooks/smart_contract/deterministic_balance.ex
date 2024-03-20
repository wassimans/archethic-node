defmodule Archethic.Utils.Regression.Playbook.SmartContract.DeterministicBalance do
  @moduledoc """
  This contract is triggered by transactions
  It will log each balance updates for each transaction received
  """

  alias Archethic.Crypto
  alias Archethic.TransactionChain.TransactionData
  alias Archethic.TransactionChain.TransactionData.Ledger
  alias Archethic.TransactionChain.TransactionData.UCOLedger
  alias Archethic.TransactionChain.TransactionData.UCOLedger.Transfer, as: UCOTransfer
  alias Archethic.Utils.Regression.Api
  alias Archethic.Utils.Regression.Playbook.SmartContract

  require Logger

  def play(storage_nonce_pubkey, endpoint) do
    Logger.info("============== CONTRACT: DETERMINISTIC BALANCE =============")
    contract_seed = SmartContract.random_seed()

    nb_transactions = 100
    triggers_seeds = Enum.map(1..nb_transactions, fn _ -> SmartContract.random_seed() end)

    initial_funds =
      Enum.reduce(triggers_seeds, %{contract_seed => 505}, fn seed, acc ->
        Map.put(acc, seed, 15)
      end)

    Api.send_funds_to_seeds(initial_funds, endpoint)

    genesis_address =
      Crypto.derive_keypair(contract_seed, 0) |> elem(0) |> Crypto.derive_address()

    Logger.info("Contract at #{Base.encode16(genesis_address)}")

    contract_address =
      SmartContract.deploy(
        contract_seed,
        %TransactionData{
          content: "505",
          code: contract_code()
        },
        storage_nonce_pubkey,
        endpoint
      )

    ledger = %Ledger{
      uco: %UCOLedger{
        transfers: [%UCOTransfer{to: contract_address, amount: Archethic.Utils.to_bigint(10)}]
      }
    }

    Task.async_stream(
      triggers_seeds,
      fn seed ->
        SmartContract.trigger(seed, contract_address, endpoint,
          await_timeout: 60_000,
          ledger: ledger
        )
      end,
      max_concurrency: length(triggers_seeds),
      timeout: :infinity
    )
    |> Stream.run()

    SmartContract.await_no_more_calls(genesis_address, endpoint)

    %{"data" => %{"content" => logged_balance}} =
      Api.get_last_transaction(contract_address, endpoint)

    logged_balance = logged_balance |> String.to_float() |> Float.ceil()

    expected_balance = 505.0 - 5 + (nb_transactions - 1) * (10 - 5)

    if logged_balance == expected_balance do
      Logger.info("Smart contract 'deterministic balance' has been updated successfully")
      :ok
    else
      Logger.error(
        "Smart contract 'deterministic balance' has not been updated successfully: #{logged_balance} - expected #{expected_balance}"
      )

      :error
    end
  end

  defp contract_code() do
    ~s"""
    @version 1

    # GENERATED BY PLAYBOOK

    condition inherit: [
      content: (
        log(previous.balance.uco)
        log(next.balance.uco)
        diff = ceil(previous.balance.uco) - ceil(next.balance.uco)
        abs(diff) == 5.0
      ),
      uco_transfers: ["00000000000000000000000000000000000000000000000000000000000000000000": 5]
    ]

    fun ceil(number) do
      number + (1 - Math.rem(number, 1))
    end

    fun abs(number) do
      if number >= 0 do
        number
      else
        number * -1
      end
    end

    condition transaction: []
    actions triggered_by: transaction do
      Contract.add_uco_transfer to: 0x00000000000000000000000000000000000000000000000000000000000000000000, amount: 5
      Contract.set_content(String.from_number(contract.balance.uco - 5.0))
    end
    """
  end
end
