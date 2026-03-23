defmodule SubspaceWeb.FirehoseChannel do
  use SubspaceWeb, :channel

  @impl true
  def join("firehose", _params, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    push(socket, "server_hello", %{
      type: "server_hello",
      server_name: System.get_env("SERVER_NAME", "Subspace"),
      server_url: SubspaceWeb.Endpoint.url()
    })

    {:noreply, socket}
  end
end
