defmodule Player.Crawler do
  @moduledoc """
  Punto de entrada que usa el harness: `start/2` lanza una `Player.Busqueda`
  bajo el `Player.CrawlerSupervisor` y `status/1` lee de ETS el último estado
  publicado (nunca se bloquea).
  """

  @behaviour WikiRace.Crawler

  @impl WikiRace.Crawler
  def start(url_inicio, url_objetivo) do
    detener_anterior()

    resultado =
      DynamicSupervisor.start_child(
        Player.CrawlerSupervisor,
        {Player.Busqueda, {url_inicio, url_objetivo}}
      )

    case resultado do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, razon} -> {:error, razon}
      :ignore -> {:error, :ignorado}
    end
  end

  @impl WikiRace.Crawler
  def status(_pid), do: Player.AlmacenEstado.obtener()

  # Cada carrera nueva empieza desde cero.
  defp detener_anterior do
    hijos = DynamicSupervisor.which_children(Player.CrawlerSupervisor)

    Enum.each(hijos, fn {_id, pid, _tipo, _modulos} ->
      if is_pid(pid) do
        DynamicSupervisor.terminate_child(Player.CrawlerSupervisor, pid)
      end
    end)

    :ok
  end
end
