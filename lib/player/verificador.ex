defmodule Player.Verificador do
  @tiempo_espera 10_000

  def verificar(camino) do
    if is_list(camino) and length(camino) >= 2 do
      canonicos = Enum.map(camino, fn url -> canonico(url) end)

      if length(Enum.uniq(canonicos)) != length(camino) do
        {:error, :articulo_duplicado}
      else
        verificar_saltos(camino)
      end
    else
      {:error, :camino_invalido}
    end
  end

  defp verificar_saltos(camino) do
    saltos = Enum.chunk_every(camino, 2, 1, :discard)

    resultados =
      saltos
      |> Task.async_stream(fn salto -> revisar_salto(salto) end,
        max_concurrency: length(saltos),
        timeout: @tiempo_espera * 2 + 2_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    fallo = Enum.find(resultados, fn resultado -> resultado != {:ok, :ok} end)

    case fallo do
      nil -> :ok
      {:ok, {:error, razon}} -> {:error, razon}
      {:exit, razon} -> {:error, {:exit, razon}}
    end
  end

  defp revisar_salto([desde, hasta]) do
    case descargar(desde, 2) do
      {:ok, cuerpo} ->
        case enlaces(cuerpo, desde) do
          {:ok, conjunto} ->
            if MapSet.member?(conjunto, canonico(hasta)) do
              :ok
            else
              {:error, {:sin_enlace, desde, hasta}}
            end

          {:error, razon} ->
            {:error, razon}
        end

      {:error, razon} ->
        {:error, razon}
    end
  end

  defp descargar(url, intentos) do
    case Req.get(url, receive_timeout: @tiempo_espera, retry: false) do
      {:ok, %{status: 200, body: cuerpo}} when is_binary(cuerpo) ->
        {:ok, cuerpo}

      {:ok, %{status: estado}} ->
        if estado >= 500 and intentos > 1 do
          descargar(url, intentos - 1)
        else
          {:error, {:http, estado}}
        end

      {:error, razon} ->
        if intentos > 1 do
          descargar(url, intentos - 1)
        else
          {:error, razon}
        end
    end
  end

  defp enlaces(cuerpo, base) do
    case Floki.parse_document(cuerpo) do
      {:ok, documento} ->
        hrefs = Floki.attribute(documento, "a", "href")
        resueltos = Enum.map(hrefs, fn href -> resolver(href, base) end)
        {:ok, MapSet.new(Enum.reject(resueltos, fn r -> is_nil(r) end))}

      {:error, razon} ->
        {:error, razon}
    end
  end

  defp resolver(href, base) do
    if String.starts_with?(href, ["#", "javascript:", "mailto:"]) do
      nil
    else
      base |> URI.merge(href) |> URI.to_string() |> canonico()
    end
  rescue
    _ -> nil
  end

  @doc false
  def canonico(url) do
    uri = URI.parse(url)
    ruta = uri.path |> to_string() |> URI.decode() |> String.trim_trailing("/")
    "#{uri.scheme}://#{uri.host}#{puerto(uri)}#{ruta}"
  end

  defp puerto(uri) do
    cond do
      uri.scheme == "http" and uri.port == 80 -> ""
      uri.scheme == "https" and uri.port == 443 -> ""
      uri.port == nil -> ""
      true -> ":#{uri.port}"
    end
  end
end
