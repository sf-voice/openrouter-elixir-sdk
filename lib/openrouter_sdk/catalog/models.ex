defmodule OpenrouterSdk.Catalog.Models do
  @moduledoc """
  hard-coded snapshot of `/api/v1/models`.

  embedded into the beam at compile time so lookups are zero-io. the
  contents are managed by `mix openrouter.snapshot` and kept fresh by
  ci — see `.github/workflows/openrouter-drift.yml`.

  the catalog is purely informational. nothing in this sdk validates
  that a model id passed to `Api.Chat.completions/2` exists here —
  consumers can use this list to drive their own routing / rotation /
  fallback policies.
  """

  @models_path Path.join(:code.priv_dir(:openrouter_sdk) |> to_string(), "openrouter/models.json")
  @version_path Path.join(
                  :code.priv_dir(:openrouter_sdk) |> to_string(),
                  "openrouter/schema_version.txt"
                )

  @external_resource @models_path
  @external_resource @version_path

  @raw File.read!(@models_path)
  # decode at compile time. prefer built-in JSON (elixir 1.18+); fall
  # back to Jason if the host has it loaded during compilation.
  @snapshot (cond do
               function_exported?(JSON, :decode!, 1) -> JSON.decode!(@raw)
               Code.ensure_loaded?(Jason) -> Jason.decode!(@raw)
               true -> %{"data" => []}
             end)
  @models Map.get(@snapshot, "data", [])
  @version File.read!(@version_path) |> String.trim()

  @doc "snapshot version (iso date or `unseeded`)"
  @spec version() :: String.t()
  def version, do: @version

  @doc "all models in the snapshot"
  @spec list() :: [map()]
  def list, do: @models

  @doc """
  filter the snapshot.

  supported keys: `:modality`, `:supported_parameter`, `:provider_id`.
  """
  @spec list(keyword()) :: [map()]
  def list(filters) when is_list(filters) do
    Enum.filter(@models, &matches?(&1, filters))
  end

  @doc "lookup by id, returns nil if absent"
  @spec get(String.t()) :: map() | nil
  def get(id) when is_binary(id) do
    Enum.find(@models, &(&1["id"] == id))
  end

  @doc "context length for a model id, or nil"
  @spec context_length(String.t()) :: integer() | nil
  def context_length(id) do
    case get(id) do
      %{"context_length" => n} -> n
      _ -> nil
    end
  end

  @doc "pricing map for a model id, or nil"
  @spec pricing(String.t()) :: map() | nil
  def pricing(id) do
    case get(id) do
      %{"pricing" => p} -> p
      _ -> nil
    end
  end

  defp matches?(model, filters) do
    Enum.all?(filters, fn
      {:modality, m} ->
        modalities = get_in(model, ["architecture", "output_modalities"]) || []
        m in modalities or m == get_in(model, ["architecture", "modality"])

      {:supported_parameter, p} ->
        params = model["supported_parameters"] || []
        to_string(p) in Enum.map(params, &to_string/1)

      {:provider_id, p} ->
        get_in(model, ["top_provider", "id"]) == p

      _ ->
        true
    end)
  end
end
