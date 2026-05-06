defmodule Mix.Tasks.Openrouter.Snapshot do
  @shortdoc "refresh the hard-coded openrouter model + provider snapshot"

  @moduledoc """
  fetches `/api/v1/models` and `/api/v1/providers` from openrouter and
  writes them into `priv/openrouter/`. designed for ci to call on a
  schedule and auto-open a pr when drift exists.

  ## usage

      mix openrouter.snapshot           # write snapshot, bump version
      mix openrouter.snapshot --check   # exit non-zero on drift (pr gate)

  network calls go via `:httpc` so we don't depend on a live finch
  pool while compiling. no api key is required for either endpoint.
  """

  use Mix.Task

  @models_url ~c"https://openrouter.ai/api/v1/models"
  @providers_url ~c"https://openrouter.ai/api/v1/providers"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [check: :boolean])
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    models = fetch!(@models_url)
    providers = fetch!(@providers_url)
    version = Date.utc_today() |> Date.to_iso8601()

    targets = [
      {"priv/openrouter/models.json", encode(models)},
      {"priv/openrouter/providers.json", encode(providers)},
      {"priv/openrouter/schema_version.txt", version <> "\n"}
    ]

    if opts[:check] do
      drift = Enum.filter(targets, fn {path, expected} -> read(path) != expected end)

      if drift == [] do
        Mix.shell().info("openrouter snapshot: up to date")
      else
        Mix.shell().error("openrouter snapshot drift in:")
        Enum.each(drift, fn {path, _} -> Mix.shell().error("  #{path}") end)
        exit({:shutdown, 1})
      end
    else
      Enum.each(targets, fn {path, content} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        Mix.shell().info("wrote #{path}")
      end)
    end
  end

  defp fetch!(url) do
    headers = [{~c"user-agent", ~c"openrouter_sdk-snapshot/0.1"}]
    request = {url, headers}
    opts = [timeout: 30_000, ssl: ssl_opts()]

    case :httpc.request(:get, request, opts, []) do
      {:ok, {{_, 200, _}, _, body}} ->
        body |> IO.iodata_to_binary() |> decode!()

      other ->
        Mix.raise("openrouter snapshot fetch failed for #{url}: #{inspect(other)}")
    end
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  # encode with stable key ordering so diffs stay clean
  defp encode(term) do
    sorted = sort(term)

    cond do
      function_exported?(JSON, :encode_to_iodata!, 1) ->
        sorted |> JSON.encode_to_iodata!() |> IO.iodata_to_binary() |> Kernel.<>("\n")

      Code.ensure_loaded?(Jason) ->
        Jason.encode_to_iodata!(sorted, pretty: false) |> IO.iodata_to_binary() |> Kernel.<>("\n")

      true ->
        Mix.raise("no json encoder available (need elixir 1.18+ or :jason)")
    end
  end

  defp decode!(binary) do
    cond do
      function_exported?(JSON, :decode!, 1) -> JSON.decode!(binary)
      Code.ensure_loaded?(Jason) -> Jason.decode!(binary)
      true -> Mix.raise("no json decoder available")
    end
  end

  # recursively sort map keys for deterministic output. lists keep their order.
  defp sort(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {k, sort(v)} end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.into(%{})
  end

  defp sort(list) when is_list(list), do: Enum.map(list, &sort/1)
  defp sort(other), do: other

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end
end
