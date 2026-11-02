defmodule Player.Busqueda do
  use GenServer, restart: :temporary

  require Logger

  alias Player.{AlmacenEstado, Enlaces, Verificador}
  alias WikiRace.{Harness, Status}

  @max_concurrencia 36
  @max_descubiertos 800_000
  @tiempo_descarga 8_000
  @intentos_descarga 2
  @intentos_inicio 5

  defmodule Estado do
    @moduledoc false
    defstruct sitio: nil,
              url_inicio: nil,
              url_objetivo: nil,
              resto_objetivo: nil,
              clave_objetivo: nil,
              visitados: nil,
              caliente: MapSet.new(),
              cola_caliente: :queue.new(),
              largo_caliente: 0,
              cola: :queue.new(),
              largo: 0,
              en_vuelo: 0,
              tareas: %{},
              descargadas: 0,
              actual: nil,
              mejor: nil,
              largo_mejor: 1_000_000,
              agotado: false
  end

  def start_link({url_inicio, url_objetivo}) do
    GenServer.start_link(__MODULE__, {url_inicio, url_objetivo})
  end

  @impl true
  def init({url_inicio, url_objetivo}) do
    case crear_estado(url_inicio, url_objetivo) do
      {:ok, estado} ->
        AlmacenEstado.guardar(Status.new(state: :running))
        {:ok, estado, {:continue, :arrancar}}

      :error ->
        {:stop, :urls_invalidas}
    end
  end

  @impl true
  def handle_continue(:arrancar, estado) do
    estado = lanzar_tarea_objetivo(estado)
    estado = despachar(estado)
    estado = publicar(estado)
    {:noreply, estado}
  end

  @impl true
  def handle_info({ref, resultado}, estado) when is_reference(ref) do
    case Map.pop(estado.tareas, ref) do
      {nil, _tareas} ->
        {:noreply, estado}

      {tipo, tareas} ->
        Process.demonitor(ref, [:flush])
        {:noreply, asentar(%{estado | tareas: tareas}, tipo, resultado)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _razon}, estado) do
    case Map.pop(estado.tareas, ref) do
      {nil, _tareas} -> {:noreply, estado}
      {tipo, tareas} -> {:noreply, asentar(%{estado | tareas: tareas}, tipo, :caida)}
    end
  end

  def handle_info(_otro, estado), do: {:noreply, estado}


  defp crear_estado(url_inicio, url_objetivo) do
    case Enlaces.sitio(url_inicio) do
      {:ok, sitio} ->
        inicio = Enlaces.partir_url(sitio, url_inicio)
        objetivo = Enlaces.partir_url(sitio, url_objetivo)

        case {inicio, objetivo} do
          {{:ok, resto_inicio, clave_inicio}, {:ok, resto_objetivo, clave_objetivo}} ->
            visitados =
              :ets.new(:visitados, [
                :set,
                :public,
                write_concurrency: true,
                read_concurrency: true
              ])

            :ets.insert(visitados, {clave_inicio, resto_inicio, nil, 0})
            :ets.insert(visitados, {clave_objetivo, nil, nil, -1})

            {:ok,
             %Estado{
               sitio: sitio,
               url_inicio: url_inicio,
               url_objetivo: url_objetivo,
               resto_objetivo: resto_objetivo,
               clave_objetivo: clave_objetivo,
               visitados: visitados,
               cola: :queue.in({clave_inicio, resto_inicio, 0}, :queue.new()),
               largo: 1
             }}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp asentar(estado, tipo, resultado) do
    estado = aplicar_resultado(estado, tipo, resultado)
    estado = despachar(estado)
    estado = revisar_agotado(estado)
    publicar(estado)
  end

  defp aplicar_resultado(estado, tipo, resultado) do
    case {tipo, resultado} do
      {:rastreo, {:listo, clave, profundidad, encontrado?, nuevos}} ->
        estado= %{
          estado
          | en_vuelo: estado.en_vuelo - 1,
            descargadas: estado.descargadas + 1,
            actual: clave
        }

        estado= encolar(estado, nuevos, profundidad + 1)
        if encontrado? do
          candidato(estado, clave)
        else
          estado
        end

      {:rastreo, _fallo_o_caida} ->
        %{estado | en_vuelo: estado.en_vuelo - 1}

      {:objetivo, {:ok, claves}} ->
        promover(%{estado | caliente: MapSet.new(claves)})

      {:objetivo, _otro} ->
        estado

      {{:verificar, largo, camino}, :ok} ->
        if largo < estado.largo_mejor do
          Harness.report(camino)
          Logger.info("camino verificado y reportado (#{largo} artículos)")
          %{estado | mejor: camino, largo_mejor: largo}
        else
          estado
        end

      {{:verificar, _largo, _camino}, otro} ->
        Logger.warning("camino candidato rechazado: #{inspect(otro)}")
        estado
    end
  end

  defp candidato(estado, clave) do
    camino = ancestros(estado, clave, []) ++ [estado.url_objetivo]
    largo = length(camino)

    if hd(camino) == estado.url_inicio and largo < limite_aceptable(estado) do
      tarea =
        Task.Supervisor.async_nolink(Player.TaskSupervisor, fn ->
          Verificador.verificar(camino)
        end)

      tareas = Map.put(estado.tareas, tarea.ref, {:verificar, largo, camino})
      %{estado | tareas: tareas}
    else
      estado
    end
  end

  #Reconstruye el camino desde el inicio hasta al padre
  defp ancestros(estado, clave, acumulado) do
    case :ets.lookup(estado.visitados, clave) do
      [{_clave, _resto, nil, _profundidad}] ->
        [estado.url_inicio | acumulado]

      [{_clave, resto, padre, _profundidad}] ->
        ancestros(estado, padre, [Enlaces.url_para(estado.sitio, resto) | acumulado])

      _ ->
        acumulado
    end
  end

  defp limite_aceptable(estado) do
    verificaciones = Enum.filter(Map.values(estado.tareas), fn t -> match?({:verificar, _, _}, t) end)
    pendientes = Enum.map(verificaciones, fn {:verificar, largo, _camino} -> largo end)
    Enum.min([estado.largo_mejor | pendientes])
  end

  defp encolar(estado, nuevos, profundidad) do
    Enum.reduce(nuevos, estado, fn {clave, resto}, acc ->
      item = {clave, resto, profundidad}

      if MapSet.member?(acc.caliente, clave) do
        %{acc | cola_caliente: :queue.in(item, acc.cola_caliente), largo_caliente: acc.largo_caliente + 1}
      else
        %{acc | cola: :queue.in(item, acc.cola), largo: acc.largo + 1}
      end
    end)
  end

  defp promover(estado) do
    items = :queue.to_list(estado.cola)

    {calientes, normales} = Enum.split_with(items, fn {clave, _resto, _prof} -> MapSet.member?(estado.caliente, clave) end)

    cola_caliente = Enum.reduce(calientes, estado.cola_caliente, fn item, cola -> :queue.in(item, cola) end)

    %{
      estado
      | cola_caliente: cola_caliente,
        largo_caliente: estado.largo_caliente + length(calientes),
        cola: :queue.from_list(normales),
        largo: length(normales)
    }
  end

  defp despachar(estado) do
    if estado.en_vuelo >= @max_concurrencia do
      estado
    else
      case siguiente_item(estado) do
        {nil, estado} ->
          estado

        {item, estado} ->
          estado = lanzar_rastreo(estado, item)
          despachar(estado)
      end
    end
  end

  defp siguiente_item(estado) do
    cond do
      estado.largo_caliente > 0 ->
        {{:value, item}, cola} = :queue.out(estado.cola_caliente)
        estado = %{estado | cola_caliente: cola, largo_caliente: estado.largo_caliente - 1}
        tomar(estado, item)

      estado.largo > 0 ->
        {{:value, item}, cola} = :queue.out(estado.cola)
        estado = %{estado | cola: cola, largo: estado.largo - 1}
        tomar(estado, item)

      true ->
        {nil, estado}
    end
  end

  defp tomar(estado, {_clave, _resto, profundidad} = item) do
    if profundidad + 2 >= estado.largo_mejor do
      siguiente_item(estado)
    else
      {item, estado}
    end
  end

  defp lanzar_rastreo(estado, {clave, resto, profundidad}) do
    sitio = estado.sitio
    visitados = estado.visitados
    clave_objetivo = estado.clave_objetivo

    tarea =
      Task.Supervisor.async_nolink(Player.TaskSupervisor, fn ->
        rastrear(sitio, visitados, clave_objetivo, clave, resto, profundidad)
      end)

    tareas = Map.put(estado.tareas, tarea.ref, :rastreo)
    %{estado | tareas: tareas, en_vuelo: estado.en_vuelo + 1}
  end

  defp lanzar_tarea_objetivo(estado) do
    sitio = estado.sitio
    resto_objetivo = estado.resto_objetivo

    tarea =
      Task.Supervisor.async_nolink(Player.TaskSupervisor, fn ->
        enlaces_objetivo(sitio, resto_objetivo)
      end)

    %{estado | tareas: Map.put(estado.tareas, tarea.ref, :objetivo)}
  end

  defp revisar_agotado(estado) do
    sin_trabajo =
      estado.agotado == false and estado.mejor == nil and estado.en_vuelo == 0 and estado.largo_caliente == 0 and estado.largo == 0

    if sin_trabajo do
      verificando = Enum.any?(Map.values(estado.tareas), fn t -> match?({:verificar, _, _}, t) end)

      if verificando do
        estado
      else
        Harness.report_exhausted()
        %{estado | agotado: true}
      end
    else
      estado
    end
  end

  defp publicar(estado) do
    nombre_estado =
      cond do
        estado.mejor != nil -> :found
        estado.agotado -> :exhausted
        true -> :running
      end

    url_actual =
      if estado.actual == nil do
        nil
      else
        Enlaces.url_para(estado.sitio, estado.actual)
      end

    AlmacenEstado.guardar(
      Status.new(
        current_url: url_actual,
        frontier_size: estado.largo_caliente + estado.largo,
        visited_count: estado.descargadas,
        path: estado.mejor || [],
        state: nombre_estado
      )
    )

    estado
  end

  defp rastrear(sitio, visitados, clave_objetivo, clave, resto, profundidad) do
    intentos =
      if profundidad == 0 do
        @intentos_inicio
      else
        @intentos_descarga
      end

    case descargar(Enlaces.url_para(sitio, resto), intentos) do
      {:ok, cuerpo} ->
        enlaces = Enlaces.extraer(cuerpo, sitio, resto)
        encontrado? = Enum.any?(enlaces, fn {clave_enlace, _resto} -> clave_enlace == clave_objetivo end)

        nuevos =
          if :ets.info(visitados, :size) < @max_descubiertos do
            Enum.filter(enlaces, fn {clave_enlace, resto_enlace} ->
              :ets.insert_new(visitados, {clave_enlace, resto_enlace, clave, profundidad + 1})
            end)
          else
            []
          end

        {:listo, clave, profundidad, encontrado?, nuevos}

      :error ->
        {:fallo, clave}
    end
  rescue
    _ -> {:fallo, clave}
  end

  defp enlaces_objetivo(sitio, resto_objetivo) do
    case descargar(Enlaces.url_para(sitio, resto_objetivo), 3) do
      {:ok, cuerpo} ->
        enlaces = Enlaces.extraer(cuerpo, sitio, resto_objetivo)
        {:ok, Enum.map(enlaces, fn {clave, _resto} -> clave end)}

      :error ->
        :error
    end
  rescue
    _ -> :error
  end

  defp descargar(url, intentos) do
    case Req.get(url, receive_timeout: @tiempo_descarga, retry: false, decode_body: false) do
      {:ok, %{status: 200, body: cuerpo}} when is_binary(cuerpo) ->
        {:ok, cuerpo}

      {:ok, %{status: estado}} ->
        if (estado >= 500 or estado == 429) and intentos > 1 do
          reintentar(url, intentos)
        else
          :error
        end

      {:error, _razon} ->
        if intentos > 1 do
          reintentar(url, intentos)
        else
          :error
        end
    end
  end

  defp reintentar(url, intentos) do
    Process.sleep(60)
    descargar(url, intentos - 1)
  end
end
