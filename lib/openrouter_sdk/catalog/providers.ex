defmodule OpenrouterSdk.Catalog.Providers do
  @moduledoc """
  hard-coded snapshot of `/api/v1/providers` — see
  `OpenrouterSdk.Catalog.Models` for how the snapshot is managed.
  """

  @providers_path Path.join(
                    :code.priv_dir(:openrouter_sdk) |> to_string(),
                    "openrouter/providers.json"
                  )

  @external_resource @providers_path

  @raw File.read!(@providers_path)
  @snapshot (cond do
               function_exported?(JSON, :decode!, 1) -> JSON.decode!(@raw)
               Code.ensure_loaded?(Jason) -> Jason.decode!(@raw)
               true -> %{"data" => []}
             end)
  @providers Map.get(@snapshot, "data", [])

  @spec list() :: [map()]
  def list, do: @providers

  @spec get(String.t()) :: map() | nil
  def get(id) when is_binary(id) do
    Enum.find(@providers, &(to_string(&1["id"] || &1["slug"] || &1["name"]) == id))
  end
end
