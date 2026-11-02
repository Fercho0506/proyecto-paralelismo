defmodule Player.AlmacenEstado do
  use GenServer

  @tabla :player_status

  def start_link(_opciones), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def guardar(%WikiRace.Status{} = estado) do
    :ets.insert(@tabla, {:estado, estado})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def obtener do
    case :ets.lookup(@tabla, :estado) do
      [{:estado, estado}] -> estado
      [] -> WikiRace.Status.new()
    end
  rescue
    ArgumentError -> WikiRace.Status.new()
  end

  @impl true
  def init(:ok) do
    :ets.new(@tabla, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
