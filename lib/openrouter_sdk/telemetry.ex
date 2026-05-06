defmodule OpenrouterSdk.Telemetry do
  @moduledoc """
  thin wrapper around `:telemetry.span/3`.

  emits `[:openrouter_sdk, event, :start | :stop | :exception]` so
  consumers can hook in their own tracing / metrics without us having
  to know about it.
  """

  @doc "run `fun` inside a telemetry span keyed by `event` (a list of atoms)"
  @spec span([atom()], map(), (-> {result, map()})) :: result when result: var
  def span(event, metadata, fun)
      when is_list(event) and is_map(metadata) and is_function(fun, 0) do
    :telemetry.span([:openrouter_sdk | event], metadata, fun)
  end
end
