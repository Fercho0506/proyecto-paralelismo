defmodule Player.Enlaces do
  @prefijos_ignorados ["http:", "https:", "//", "mailto:", "javascript:", "data:", "tel:", "ftp:"]
  @espacios_de_nombres ~w(File Image Category Wikipedia Help Template Portal Special Talk User
                          Draft Module MediaWiki Book TimedText WP Project Media)
  @extensiones_recurso ~w(.png .jpg .jpeg .gif .svg .webp .ico .ogg .oga .ogv .webm .mp3 .mp4
                          .pdf .tif .tiff .woff .woff2 .ttf)

  #Construye la descripcion del sitio a partir de la URL de inicio.
  def sitio(url) do
    uri = URI.parse(url)
    ruta = uri.path || ""

    prefijo =
      case String.split(ruta, "/", parts: 4) do
        ["", "content", libro, _titulo] -> "/content/" <> libro <> "/"
        _ -> nil
      end

    if is_binary(uri.host) and prefijo != nil do
      case String.split(url, prefijo, parts: 2) do
        [origen, _titulo] ->
          {:ok,
           %{
             origen: origen,
             prefijo: prefijo,
             esquema: uri.scheme,
             host: uri.host,
             puerto: uri.port
           }}

        _ ->
          {:error, :url_no_soportada}
      end
    else
      {:error, :url_no_soportada}
    end
  end

  def partir_url(sitio, url) do
    ruta = URI.parse(url).path || ""

    if String.starts_with?(ruta, sitio.prefijo) do
      largo_prefijo = byte_size(sitio.prefijo)
      resto = binary_part(ruta, largo_prefijo, byte_size(ruta) - largo_prefijo)
      {:ok, resto, clave_desde_resto(resto)}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  def url_para(sitio, resto), do: sitio.origen <> sitio.prefijo <> resto

  def clave_desde_resto(resto) do
    resto =
      if :binary.match(resto, "%") == :nomatch do
        resto
      else
        URI.decode(resto)
      end

    String.trim_trailing(resto, "/")
  end

  #Extrae los enlaces a artículos de una pagina en el orden del documento
  def extraer(cuerpo, sitio, resto_pagina) do
    uri_base = URI.parse(url_para(sitio, resto_pagina))
    plano = not String.contains?(resto_pagina, "/")

    enlaces =
      Enum.reduce(hrefs(cuerpo), [], fn crudo, acumulado ->
        case resolver(crudo, sitio, uri_base, plano) do
          nil -> acumulado
          enlace -> [enlace | acumulado]
        end
      end)

    Enum.reverse(enlaces)
  end

  defp hrefs(cuerpo) do
    tamano = byte_size(cuerpo)

    hrefs =
      Enum.reduce(:binary.matches(cuerpo, "href=\""), [], fn {posicion, largo}, acumulado ->
        inicio = posicion + largo

        case :binary.match(cuerpo, "\"", scope: {inicio, tamano - inicio}) do
          {fin, _} -> [binary_part(cuerpo, inicio, fin - inicio) | acumulado]
          :nomatch -> acumulado
        end
      end)

    Enum.reverse(hrefs)
  end

  defp resolver(crudo, sitio, uri_base, plano) do
    href = limpiar(crudo)

    if es_usable(href) do
      resto = resto_de(href, sitio, uri_base, plano)

      if is_binary(resto) and es_articulo(resto) do
        {clave_desde_resto(resto), resto}
      else
        nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp limpiar(crudo) do
    crudo =
      if :binary.match(crudo, "&") == :nomatch do
        crudo
      else
        String.replace(crudo, "&amp;", "&")
      end

    [cabeza | _] = :binary.split(crudo, ["#", "?"])
    cabeza
  end

  defp es_usable(href) do
    if href == "" do
      false
    else
      not String.starts_with?(href, @prefijos_ignorados)
    end
  end

  defp resto_de(href, sitio, uri_base, plano) do
    simple =
      if String.starts_with?(href, "./") do
        binary_part(href, 2, byte_size(href) - 2)
      else
        href
      end

    es_simple =
      plano and simple != "" and not String.starts_with?(simple, ".") and not String.contains?(simple, ["/", ":"])

    if es_simple do
      simple
    else
      resto_lento(href, sitio, uri_base)
    end
  end

  defp resto_lento(href, sitio, uri_base) do
    unido = URI.merge(uri_base, href)
    ruta = unido.path

    mismo_sitio =
      unido.scheme == sitio.esquema and unido.host == sitio.host and unido.port == sitio.puerto

    if mismo_sitio and is_binary(ruta) and String.starts_with?(ruta, sitio.prefijo) do
      largo_prefijo = byte_size(sitio.prefijo)
      binary_part(ruta, largo_prefijo, byte_size(ruta) - largo_prefijo)
    else
      nil
    end
  end

  defp es_articulo(resto) do
    cond do
      resto == "" -> false
      String.starts_with?(resto, ["-", "_"]) -> false
      es_espacio_de_nombres(resto) -> false
      es_recurso(resto) -> false
      true -> true
    end
  end

  defp es_espacio_de_nombres(resto) do
    case :binary.split(resto, ":") do
      [prefijo, _] -> prefijo in @espacios_de_nombres or String.ends_with?(prefijo, "_talk")
      _ -> false
    end
  end

  defp es_recurso(resto) do
    case :binary.match(resto, ".") do
      :nomatch -> false
      _ -> String.ends_with?(String.downcase(resto), @extensiones_recurso)
    end
  end
end
