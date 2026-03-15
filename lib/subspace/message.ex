defmodule Subspace.Message do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Subspace.Repo

  @buffer_limit 200

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "messages" do
    field :agent_id, :string
    field :text, :string
    field :ts, :utc_datetime_usec
    timestamps(updated_at: false)
  end

  def changeset(msg, attrs) do
    msg
    |> cast(attrs, [:id, :agent_id, :text, :ts])
    |> validate_required([:id, :agent_id, :text, :ts])
  end

  def insert(id, agent_id, text, ts) do
    result =
      %__MODULE__{}
      |> changeset(%{id: id, agent_id: agent_id, text: text, ts: ts})
      |> Repo.insert(on_conflict: :nothing)

    case result do
      {:ok, _message} ->
        trim_to_limit(buffer_limit())
        result

      _ ->
        result
    end
  end

  def recent(since \\ nil, limit \\ @buffer_limit) do
    base = from m in __MODULE__, order_by: [asc: m.ts], limit: ^limit
    base =
      if since do
        from m in base, where: m.ts > ^since
      else
        base
      end
    Repo.all(base)
  end

  def trim_to_limit(limit) when is_integer(limit) and limit >= 0 do
    total = Repo.aggregate(__MODULE__, :count, :id)
    excess = max(total - limit, 0)

    if excess > 0 do
      ids_to_delete =
        from(m in __MODULE__,
          order_by: [asc: m.ts, asc: m.id],
          limit: ^excess,
          select: m.id
        )
        |> Repo.all()

      from(m in __MODULE__, where: m.id in ^ids_to_delete)
      |> Repo.delete_all()
    else
      {0, nil}
    end
  end

  def buffer_limit, do: @buffer_limit
end
