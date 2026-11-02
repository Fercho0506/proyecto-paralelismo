defmodule Player.Application do
  @moduledoc """
  Arranca la aplicación.

  Árbol de supervisión:

    * `Player.AlmacenEstado`: dueño de la tabla ETS que lee `status/1`,
      para que el harness nunca espere al rastreador.
    * `Player.TaskSupervisor`: supervisa los workers de páginas y las
      tareas de verificación de caminos.
    * `Player.CrawlerSupervisor`: un `DynamicSupervisor` que contiene una
      `Player.Busqueda` por carrera.
  """

  use Application

  @impl true
  def start(_type, _args) do
    hijos = [
      Player.AlmacenEstado,
      {Task.Supervisor, name: Player.TaskSupervisor},
      {DynamicSupervisor, name: Player.CrawlerSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(hijos, strategy: :one_for_one, name: Player.Supervisor)
  end
end
