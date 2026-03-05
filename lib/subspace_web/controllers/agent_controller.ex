defmodule SubspaceWeb.AgentController do
  use SubspaceWeb, :controller

  alias Subspace.Agents
  alias Subspace.Identity.AuthTelemetry

  @mode :local_keypair

  def register_start(conn, params) do
    with {:ok, valid_params} <- validate_local_register_start(params),
         {:ok, payload} <- Agents.register_start_local(valid_params) do
      emit_http_auth(:register_start, :success, nil)
      json(conn, %{challengeId: payload.challenge_id, challenge: payload.challenge})
    else
      {:error, reason} ->
        emit_http_auth(:register_start, :failure, reason)
        error(conn, 400, "INVALID_INPUT")
    end
  end

  def register_verify(conn, params) do
    with {:ok, valid_params} <- validate_local_register_verify(params),
         {:ok, result} <- Agents.register_verify_local(valid_params) do
      emit_http_auth(:register_verify, :success, nil)

      conn
      |> put_status(:created)
      |> json(%{
        agentId: result.agent_id,
        sessionToken: result.session_token,
        name: result.name,
        owner: result.owner
      })
    else
      {:error, :already_registered} ->
        emit_http_auth(:register_verify, :failure, :already_registered)
        error(conn, 409, "ALREADY_REGISTERED")

      {:error, :signature_invalid} ->
        emit_http_auth(:register_verify, :failure, :signature_invalid)
        error(conn, 403, "SIGNATURE_INVALID")

      {:error, reason} ->
        emit_http_auth(:register_verify, :failure, reason)
        error(conn, 400, "INVALID_INPUT")
    end
  end

  def reauth_start(conn, params) do
    with {:ok, valid_params} <- validate_local_reauth_start(params),
         {:ok, payload} <- Agents.reauth_start_local(valid_params) do
      emit_http_auth(:reauth_start, :success, nil)
      json(conn, %{challengeId: payload.challenge_id, challenge: payload.challenge})
    else
      {:error, :not_found} ->
        emit_http_auth(:reauth_start, :failure, :not_found)
        error(conn, 404, "NOT_FOUND")

      {:error, :banned} ->
        emit_http_auth(:reauth_start, :failure, :banned)
        error(conn, 403, "BANNED")

      {:error, reason} ->
        emit_http_auth(:reauth_start, :failure, reason)
        error(conn, 400, "INVALID_INPUT")
    end
  end

  def reauth_verify(conn, params) do
    with {:ok, valid_params} <- validate_local_reauth_verify(params),
         {:ok, result} <- Agents.reauth_verify_local(valid_params) do
      emit_http_auth(:reauth_verify, :success, nil)
      json(conn, %{agentId: result.agent_id, sessionToken: result.session_token})
    else
      {:error, :not_found} ->
        emit_http_auth(:reauth_verify, :failure, :not_found)
        error(conn, 404, "NOT_FOUND")

      {:error, :banned} ->
        emit_http_auth(:reauth_verify, :failure, :banned)
        error(conn, 403, "BANNED")

      {:error, :signature_invalid} ->
        emit_http_auth(:reauth_verify, :failure, :signature_invalid)
        error(conn, 403, "SIGNATURE_INVALID")

      {:error, reason} ->
        emit_http_auth(:reauth_verify, :failure, reason)
        error(conn, 400, "INVALID_INPUT")
    end
  end

  defp validate_local_register_start(params) do
    with {:ok, name} <- required_nonempty_string(params, "name"),
         {:ok, owner} <- required_nonempty_string(params, "owner"),
         {:ok, public_key} <- required_nonempty_string(params, "publicKey") do
      {:ok, %{"name" => name, "owner" => owner, "public_key" => public_key}}
    end
  end

  defp validate_local_register_verify(params) do
    with {:ok, challenge_id} <- required_nonempty_string(params, "challengeId"),
         {:ok, name} <- required_nonempty_string(params, "name"),
         {:ok, owner} <- required_nonempty_string(params, "owner"),
         {:ok, public_key} <- required_nonempty_string(params, "publicKey"),
         {:ok, signature} <- required_nonempty_string(params, "signature") do
      {:ok,
       %{
         "challenge_id" => challenge_id,
         "name" => name,
         "owner" => owner,
         "public_key" => public_key,
         "signature" => signature
       }}
    end
  end

  defp validate_local_reauth_start(params) do
    with {:ok, agent_id} <- required_nonempty_string(params, "agentId") do
      {:ok, %{"agent_id" => agent_id}}
    end
  end

  defp validate_local_reauth_verify(params) do
    with {:ok, challenge_id} <- required_nonempty_string(params, "challengeId"),
         {:ok, agent_id} <- required_nonempty_string(params, "agentId"),
         {:ok, signature} <- required_nonempty_string(params, "signature") do
      {:ok,
       %{
         "challenge_id" => challenge_id,
         "agent_id" => agent_id,
         "signature" => signature
       }}
    end
  end

  defp required_nonempty_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        if byte_size(String.trim(value)) > 0 do
          {:ok, value}
        else
          {:error, :invalid_input}
        end

      _ ->
        {:error, :invalid_input}
    end
  end

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: error_message(code), code: code})
  end

  defp emit_http_auth(operation, outcome, reason) do
    AuthTelemetry.emit_http(operation, outcome, reason, @mode)
  end

  defp error_message("INVALID_INPUT"), do: "invalid input"
  defp error_message("ALREADY_REGISTERED"), do: "conflict"
  defp error_message("SIGNATURE_INVALID"), do: "forbidden"
  defp error_message("NOT_FOUND"), do: "not found"
  defp error_message("BANNED"), do: "forbidden"
  defp error_message(_), do: "internal error"
end
