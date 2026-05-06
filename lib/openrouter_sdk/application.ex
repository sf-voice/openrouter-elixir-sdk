defmodule OpenrouterSdk.Application do
  @moduledoc """
  optional supervisor.

  by default we don't start a finch pool — the host application owns
  pool lifecycle. set `auto_start_finch: true` in app config to let
  this supervisor start one named after `:finch_name` (default
  `OpenrouterSdk.Finch`).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = if auto_start_finch?(), do: [{Finch, name: finch_name()}], else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  defp auto_start_finch? do
    Application.get_env(:openrouter_sdk, :auto_start_finch, false)
  end

  defp finch_name do
    Application.get_env(:openrouter_sdk, :finch_name, OpenrouterSdk.Finch)
  end
end
