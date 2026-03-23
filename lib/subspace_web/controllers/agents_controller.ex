defmodule SubspaceWeb.AgentsController do
  use SubspaceWeb, :controller

  alias Subspace.Agents

  def register_start(conn, params) do
    input = %{
      "name" => params["name"],
      "owner" => params["owner"],
      "public_key" => params["publicKey"]
    }

    case Agents.register_start_local(input) do
      {:ok, result} ->
        conn
        |> put_status(200)
        |> json(%{challengeId: result.challenge_id, challenge: result.challenge})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def register_verify(conn, params) do
    input = %{
      "challenge_id" => params["challengeId"],
      "name" => params["name"],
      "owner" => params["owner"],
      "public_key" => params["publicKey"],
      "signature" => params["signature"]
    }

    case Agents.register_verify_local(input) do
      {:ok, result} ->
        conn
        |> put_status(201)
        |> json(%{
          agentId: result.agent_id,
          sessionToken: result.session_token,
          name: result.name,
          owner: result.owner
        })

      {:error, :already_registered} ->
        conn
        |> put_status(409)
        |> json(%{error: "ALREADY_REGISTERED"})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def reauth_start(conn, params) do
    input = %{"agent_id" => params["agentId"]}

    case Agents.reauth_start_local(input) do
      {:ok, result} ->
        conn
        |> put_status(200)
        |> json(%{challengeId: result.challenge_id, challenge: result.challenge})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def reauth_verify(conn, params) do
    input = %{
      "challenge_id" => params["challengeId"],
      "agent_id" => params["agentId"],
      "signature" => params["signature"]
    }

    case Agents.reauth_verify_local(input) do
      {:ok, result} ->
        conn
        |> put_status(200)
        |> json(%{agentId: result.agent_id, sessionToken: result.session_token})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  defp error_response(conn, :not_found) do
    conn |> put_status(404) |> json(%{error: "NOT_FOUND"})
  end

  defp error_response(conn, :banned) do
    conn |> put_status(403) |> json(%{error: "BANNED"})
  end

  defp error_response(conn, :signature_invalid) do
    conn |> put_status(401) |> json(%{error: "SIGNATURE_INVALID"})
  end

  defp error_response(conn, :invalid_input) do
    conn |> put_status(422) |> json(%{error: "INVALID_INPUT"})
  end

  defp error_response(conn, _reason) do
    conn |> put_status(400) |> json(%{error: "BAD_REQUEST"})
  end
end
