defmodule Uniris.Bootstrap do
  @moduledoc """
  Uniris node bootstraping

  The first node in the network will initialized the first node shared secrets and genesis wallets as well as his own
  node transactions. Those transactions will self validated and self replicated.

  Other nodes initialize or update (if ip, port change or disconnected from long time) their own node transaction chain.
  They start to synchronize from the Beacon chain to retreive the necessary items to be part of the network.

  Once the synchronization/self repair mechanism is terminated, the node will publish to the Beacon chain its ready and completion.
  After the self repair/sync others nodes will be able to communicate with him and start validate other transactions.
  """
  use Task

  require Logger

  alias Uniris.Crypto

  alias Uniris.Beacon
  alias Uniris.BeaconSlot.NodeInfo

  alias __MODULE__.IPLookup
  alias __MODULE__.NetworkInit

  alias Uniris.P2P
  alias Uniris.P2P.BootstrapingSeeds
  alias Uniris.P2P.GeoPatch
  alias Uniris.P2P.Message.AddNodeInfo
  alias Uniris.P2P.Message.BootstrappingNodes
  alias Uniris.P2P.Message.EncryptedStorageNonce
  alias Uniris.P2P.Message.GetBootstrappingNodes
  alias Uniris.P2P.Message.GetStorageNonce
  alias Uniris.P2P.Message.ListNodes
  alias Uniris.P2P.Message.NewTransaction
  alias Uniris.P2P.Message.NodeList
  alias Uniris.P2P.Node

  alias Uniris.SelfRepair

  alias Uniris.Storage.Memory.NetworkLedger

  alias Uniris.Transaction
  alias Uniris.TransactionData

  def start_link(opts) do
    ip = IPLookup.get_ip()

    port = Keyword.get(opts, :port)

    Task.start_link(__MODULE__, :run, [
      ip,
      port,
      SelfRepair.last_sync_date(),
      BootstrapingSeeds.list()
    ])
  end

  def run(ip, port, last_sync_date, bootstraping_seeds) do
    Logger.info("Bootstraping starting")

    first_public_key = Crypto.node_public_key(0)
    patch = GeoPatch.from_ip(ip)

    if initialized_network?(first_public_key, bootstraping_seeds) do
      if Crypto.number_of_node_keys() == 0 do
        Logger.info("Node initialization...")
        first_initialization(ip, port, patch, bootstraping_seeds)
      else
        if require_node_update?(ip, port, last_sync_date) do
          Logger.info("Update node chain...")

          case Enum.reject(
                 bootstraping_seeds,
                 &(&1.first_public_key == Crypto.node_public_key(0))
               ) do
            [] ->
              Logger.warn("Not enought nodes in the network. No node update")
              :ok

            _ ->
              update_node(ip, port, patch, bootstraping_seeds)
          end
        else
          :ok
        end
      end
    else
      init_network(ip, port, patch)
    end

    Logger.info("Bootstraping finished!")
  end

  defp initialized_network?(first_public_key, bootstraping_seeds) do
    with {:error, :not_found} <-
           NetworkLedger.get_last_node_shared_secrets_address(),
         [%Node{first_public_key: key} | _] when key == first_public_key <- bootstraping_seeds do
      false
    else
      _ ->
        true
    end
  end

  defp require_node_update?(ip, port, last_sync_date) do
    diff_sync = DateTime.diff(DateTime.utc_now(), last_sync_date, :second)

    case P2P.node_info() do
      # TODO: change the diff sync parameter when the self repair will be moved to daily
      {:ok, %Node{ip: prev_ip, port: prev_port}}
      when ip != prev_ip or port != prev_port or diff_sync > 3 ->
        true

      _ ->
        false
    end
  end

  defp init_network(ip, port, patch) do
    Logger.info("Network initialization...")
    NetworkInit.create_storage_nonce()

    Logger.info("Create first node transaction")
    tx = create_node_transaction(ip, port)

    tx
    |> NetworkInit.self_validation!()
    |> NetworkInit.self_replication()

    Process.sleep(200)

    NetworkLedger.set_node_ready(Crypto.node_public_key(0), tx.timestamp)

    network_pool_seed = :crypto.strong_rand_bytes(32)
    NetworkInit.init_node_shared_secrets_chain(network_pool_seed)

    {pub, _} = Crypto.derivate_keypair(network_pool_seed, 0)
    network_pool_address = Crypto.hash(pub)
    NetworkInit.init_genesis_wallets(network_pool_address)

    SelfRepair.start_sync(patch, false)
  end

  defp first_initialization(ip, port, patch, bootstraping_seeds) do
    %BootstrappingNodes{closest_nodes: closest_nodes, new_seeds: new_seeds} =
      bootstraping_seeds
      |> Enum.random()
      |> P2P.send_message(%GetBootstrappingNodes{patch: patch})

    load_nodes(new_seeds ++ closest_nodes)
    BootstrapingSeeds.update(new_seeds)

    Logger.info("Create first node transaction")
    tx = create_node_transaction(ip, port)
    send_message(%NewTransaction{transaction: tx}, closest_nodes)

    case P2P.send_message(
           List.first(closest_nodes),
           %GetStorageNonce{public_key: Crypto.node_public_key()}
         ) do
      %EncryptedStorageNonce{digest: encrypted_nonce} ->
        Crypto.decrypt_and_set_storage_nonce(encrypted_nonce)
        Logger.info("Storage nonce set")

        %NodeList{nodes: nodes} = P2P.send_message(List.first(closest_nodes), %ListNodes{})
        load_nodes(nodes)
        Logger.info("Node list refreshed")

        Logger.info("Start synchronization")

        SelfRepair.start_sync(patch)

        receive do
          :sync_finished ->
            publish_readyness()
        end

      _ ->
        Logger.error("Transaction failed")
    end
  end

  defp update_node(ip, port, patch, bootstraping_seeds) do
    %BootstrappingNodes{closest_nodes: closest_nodes, new_seeds: new_seeds} =
      bootstraping_seeds
      |> Enum.random()
      |> P2P.send_message(%GetBootstrappingNodes{patch: patch})

    :ok = BootstrapingSeeds.update(new_seeds)
    :ok = load_nodes(new_seeds ++ closest_nodes)
    Logger.info("Node list refreshed")

    tx = create_node_transaction(ip, port)
    send_message(%NewTransaction{transaction: tx}, closest_nodes)

    Logger.info("Start synchronization")
    SelfRepair.start_sync(patch)

    receive do
      :sync_finished ->
        publish_readyness()
    end
  end

  defp publish_readyness do
    subset = Beacon.subset_from_address(Crypto.node_public_key(0))

    ready_date = DateTime.utc_now()

    subset
    |> Beacon.get_pool(ready_date)
    |> Task.async_stream(fn node ->
      P2P.send_message(
        node,
        %AddNodeInfo{
          subset: subset,
          node_info: %NodeInfo{
            public_key: Crypto.node_public_key(),
            ready?: true,
            timestamp: ready_date
          }
        }
      )
    end)
    |> Stream.run()
  end

  defp create_node_transaction(ip, port) do
    Transaction.new(:node, %TransactionData{
      content: """
      ip: #{stringify_ip(ip)}
      port: #{port}
      """
    })
  end

  defp load_nodes(nodes) do
    nodes
    |> Enum.uniq()
    |> Enum.each(&NetworkLedger.add_node_info/1)
  end

  defp stringify_ip(ip), do: :inet_parse.ntoa(ip)

  defp send_message(msg, [closest_node | rest]) do
    P2P.send_message(closest_node, msg)
  rescue
    e ->
      Logger.error(Exception.format(:error, e, __STACKTRACE__))
      send_message(msg, rest)
  end

  defp send_message(_, []), do: raise("Network issue")
end
