defmodule SubspaceWeb.EndpointSocketTransportTest do
  use ExUnit.Case, async: true

  test "mounts firehose socket transport at /api/firehose/stream" do
    assert Enum.any?(SubspaceWeb.Endpoint.__sockets__(), fn
             {"/api/firehose/stream", SubspaceWeb.FirehoseSocket, opts} ->
               Keyword.get(opts, :websocket) == true and Keyword.get(opts, :longpoll) == false

             _ ->
               false
           end)
  end

  test "routes websocket transport path through endpoint socket handler" do
    conn =
      Plug.Test.conn("GET", "/api/firehose/stream/websocket?vsn=2.0.0")
      |> Plug.Conn.put_req_header("connection", "Upgrade")
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> Plug.Conn.put_req_header("sec-websocket-version", "13")
      |> Plug.Conn.put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
      |> SubspaceWeb.Endpoint.call([])

    # Socket transport handles the request path and fails later on missing host header.
    assert conn.status == 400
    assert conn.resp_body =~ "host"
  end
end
