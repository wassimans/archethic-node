defmodule ArchethicWeb.GraphQLSchema.Resolver do
  @moduledoc false

  alias Archethic

  alias Archethic.Crypto

  alias Archethic.P2P

  alias Archethic.BeaconChain
  alias Archethic.BeaconChain.SummaryAggregate
  alias Archethic.BeaconChain.Subset.P2PSampling

  alias Archethic.TransactionChain
  alias Archethic.TransactionChain.Transaction
  alias Archethic.TransactionChain.TransactionData
  alias Archethic.TransactionChain.TransactionInput

  alias Archethic.Mining

  require Logger

  @limit_page 10

  def get_balance(address) do
    case Archethic.get_balance(address) do
      {:ok, %{uco: uco, token: token_balances}} ->
        balance = %{
          uco: uco,
          token:
            token_balances
            |> Enum.map(fn {{address, token_id}, amount} ->
              %{address: address, amount: amount, token_id: token_id}
            end)
            |> Enum.sort_by(& &1.amount)
        }

        {:ok, balance}

      {:error, :network_issue} = e ->
        e
    end
  end

  def get_token(address) do
    t1 = Task.async(fn -> TransactionChain.fetch_genesis_address_remotely(address) end)
    t2 = Task.async(fn -> get_transaction_content(address) end)

    with {:ok, {:ok, genesis_address}} <- Task.yield(t1),
         {:ok,
          {:ok,
           definition = %{
             "ownerships" => ownerships,
             "supply" => supply,
             "type" => type
           }}} <- Task.yield(t2) do
      properties = Map.get(definition, "properties", %{})
      collection = Map.get(definition, "collection", [])
      decimals = Map.get(definition, "decimals", 8)
      name = Map.get(definition, "name", "")
      symbol = Map.get(definition, "symbol", "")

      data_to_digest = %{
        genesis_address: Base.encode16(genesis_address),
        name: name,
        symbol: symbol,
        properties: properties,
        decimals: decimals
      }

      token_id = :crypto.hash(:sha256, Jason.encode!(data_to_digest)) |> Base.encode16()

      {:ok,
       %{
         genesis: genesis_address,
         name: name,
         supply: supply,
         symbol: symbol,
         type: type,
         decimals: decimals,
         properties: properties,
         collection: collection,
         ownerships: ownerships,
         id: token_id
       }}
    else
      {:ok, {:error, :network_issue}} ->
        {:error, "Network issue"}

      {:ok, {:error, :decode_error}} ->
        {:error, "Error in decoding transaction"}

      {:ok, {:error, :transaction_not_found}} ->
        {:error, "Transaction does not exist!"}

      {:exit, reason} ->
        Logger.debug("Task exited with reason")
        Logger.debug(reason)
        {:error, "Task Exited!"}

      nil ->
        {:error, "Task didn't responded within timeout!"}
    end
  end

  defp get_transaction_content(address) do
    case Archethic.search_transaction(address) do
      {:ok,
       %Transaction{data: %TransactionData{content: content, ownerships: ownerships}, type: type}}
      when type in [:token, :mint_rewards] ->
        case Jason.decode(content) do
          {:ok, map} ->
            {:ok, map |> Map.put("ownerships", ownerships)}

          _ ->
            {:error, :decode_error}
        end

      _ ->
        {:error, :transaction_not_found}
    end
  end

  def get_inputs(address, paging_offset \\ 0, limit \\ 0) do
    inputs =
      address
      |> Archethic.get_transaction_inputs(paging_offset, limit)
      |> Enum.map(&TransactionInput.to_map/1)

    case limit do
      0 ->
        {:ok, inputs}

      limit ->
        {:ok, Enum.take(inputs, limit)}
    end
  end

  def shared_secrets do
    %{
      storage_nonce_public_key: Crypto.storage_nonce_public_key()
    }
  end

  def transaction_chain_by_paging_address(address, paging_address, order) do
    case Archethic.get_transaction_chain_by_paging_address(address, paging_address, order) do
      {:ok, chain} ->
        chain = Enum.map(chain, &Transaction.to_map(&1))
        {:ok, chain}

      {:error, _} = e ->
        e
    end
  end

  def paginate_local_transactions(page) do
    paginate_transactions(TransactionChain.list_all(), page)
  end

  defp paginate_transactions(transactions, page) do
    transactions
    |> Stream.map(&Transaction.to_map/1)
    |> Stream.chunk_every(@limit_page)
    |> Enum.at(page - 1)
  end

  def get_last_transaction(address) do
    case Archethic.get_last_transaction(address) do
      {:ok, tx} ->
        {:ok, Transaction.to_map(tx)}

      {:error, _} = e ->
        e
    end
  end

  def get_transaction(address) do
    case Archethic.search_transaction(address) do
      {:ok, tx} ->
        {:ok, Transaction.to_map(tx)}

      {:error, _} = e ->
        e
    end
  end

  def get_chain_length(address) do
    Archethic.get_transaction_chain_length(address)
  end

  def nodes do
    Enum.map(
      P2P.list_nodes(),
      &%{
        first_public_key: &1.first_public_key,
        last_public_key: &1.last_public_key,
        ip: :inet.ntoa(&1.ip),
        port: &1.port,
        geo_patch: &1.geo_patch,
        network_patch: &1.network_patch,
        reward_address: &1.reward_address,
        authorized: &1.authorized?,
        available: &1.available?,
        enrollment_date: &1.enrollment_date,
        authorization_date: &1.authorization_date,
        average_availability: &1.average_availability,
        origin_public_key: &1.origin_public_key
      }
    )
  end

  def get_version do
    %{
      code: Mix.Project.config()[:version],
      protocol: Mining.protocol_version(),
      transaction: Transaction.version()
    }
  end

  def beacon_chain_summary(datetime) do
    current_datetime = DateTime.utc_now()

    next_datetime_summary_time =
      datetime
      |> BeaconChain.next_summary_date()

    previous_current_date_summary_time =
      current_datetime
      |> BeaconChain.previous_summary_time()

    authorized_nodes = P2P.authorized_and_available_nodes()

    res =
      case DateTime.compare(next_datetime_summary_time, previous_current_date_summary_time) do
        :gt ->
          next_current_date_summary_time =
            current_datetime
            |> BeaconChain.next_summary_date()

          if DateTime.compare(next_datetime_summary_time, next_current_date_summary_time) == :eq do
            datetime
            |> Archethic.list_transactions_summaries_from_current_slot()
            |> create_empty_beacon_summary_aggregate(next_current_date_summary_time)
          else
            {
              :error,
              "No data found at this date !"
            }
          end

        :eq ->
          BeaconChain.fetch_and_aggregate_summaries(next_datetime_summary_time, authorized_nodes)
          |> SummaryAggregate.aggregate()

        :lt ->
          case BeaconChain.fetch_summaries_aggregate(next_datetime_summary_time, authorized_nodes) do
            {:ok, summary} -> summary
            error -> error
          end
      end

    transform_beacon_chain_summary(res, next_datetime_summary_time)
  end

  defp create_empty_beacon_summary_aggregate(transactions_list, datetime = %DateTime{}) do
    %SummaryAggregate{
      summary_time: datetime,
      availability_adding_time: [],
      version: 1,
      transaction_summaries: transactions_list,
      p2p_availabilities: %{}
    }
  end

  defp transform_beacon_chain_summary(error = {:error, _}, _next_datetime_summary_time), do: error

  defp transform_beacon_chain_summary(beacon_chain_summary, next_datetime_summary_time) do
    transformed_beacon_chain_summary =
      beacon_chain_summary
      |> Map.update!(:p2p_availabilities, fn p2p_availabilities ->
        p2p_availabilities
        |> Map.to_list()
        |> Enum.map(fn {
                         subset,
                         subset_map
                       } ->
          list_nodes =
            P2PSampling.list_nodes_to_sample(subset)
            |> Enum.reject(
              &(DateTime.compare(&1.enrollment_date, next_datetime_summary_time) == :gt)
            )

          transform_subset_map_to_node_maps(subset_map, list_nodes)
        end)
        |> List.flatten()
      end)
      |> Map.update!(:availability_adding_time, fn
        [] -> 0
        num -> num
      end)

    {:ok, transformed_beacon_chain_summary}
  end

  defp transform_subset_map_to_node_maps(_, []), do: []

  defp transform_subset_map_to_node_maps(
         %{
           end_of_node_synchronizations: end_of_node_synchronizations,
           node_average_availabilities: node_average_availabilities,
           node_availabilities: node_availabilities
         },
         list_nodes
       ) do
    node_average_availabilities
    |> Enum.with_index()
    |> Enum.map(fn {node_average_availability, index} ->
      end_of_node_synchronization =
        end_of_node_synchronizations
        |> Enum.at(index, false)
        |> transform_end_of_node_synchronization()

      available =
        node_availabilities
        |> transform_node_availabilities()
        |> Enum.at(index)

      public_key =
        list_nodes
        |> Enum.at(index)
        |> Map.get(:first_public_key)
        |> Base.encode16()

      %{
        averageAvailability: node_average_availability,
        endOfNodeSynchronization: end_of_node_synchronization,
        available: available,
        publicKey: public_key
      }
    end)
  end

  defp transform_end_of_node_synchronization(false), do: false
  defp transform_end_of_node_synchronization(_), do: true

  defp transform_node_availabilities(bitstring, acc \\ [])

  defp transform_node_availabilities(<<1::size(1), rest::bitstring>>, acc),
    do: transform_node_availabilities(<<rest::bitstring>>, [true | acc])

  defp transform_node_availabilities(<<0::size(1), rest::bitstring>>, acc),
    do: transform_node_availabilities(<<rest::bitstring>>, [false | acc])

  defp transform_node_availabilities(<<>>, acc), do: acc

  def nearest_endpoints(ip) do
    geo_patch = P2P.get_geo_patch(ip)
    nearest_nodes = P2P.nearest_nodes(P2P.authorized_and_available_nodes(), geo_patch)

    Enum.map(
      nearest_nodes,
      &%{
        ip: :inet.ntoa(&1.ip),
        port: &1.http_port
      }
    )
  end

  def network_transactions(type, page) do
    TransactionChain.list_transactions_by_type(type, [])
    |> paginate_transactions(page)
  end
end
