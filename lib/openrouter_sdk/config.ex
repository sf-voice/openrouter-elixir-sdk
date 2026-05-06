defmodule OpenrouterSdk.Config do
  @moduledoc """
  immutable configuration for the sdk.

  built once via `new/1`, then merged with per-call opts inside each
  api function. anything you'd ever want to override on a single
  request — api key, headers, middleware — lives here.
  """

  @default_base_url "https://openrouter.ai/api/v1"
  @default_finch_name OpenrouterSdk.Finch
  @default_timeouts %{
    receive_timeout: 60_000,
    pool_timeout: 5_000,
    request_timeout: 60_000
  }

  @type t :: %__MODULE__{
          api_key: String.t() | nil,
          base_url: String.t(),
          finch_name: atom(),
          default_headers: [{String.t(), String.t()}],
          middleware: [module() | {module(), keyword()}],
          receive_timeout: pos_integer(),
          pool_timeout: pos_integer(),
          request_timeout: pos_integer(),
          telemetry_metadata: map()
        }

  defstruct api_key: nil,
            base_url: @default_base_url,
            finch_name: @default_finch_name,
            default_headers: [],
            middleware: [],
            receive_timeout: @default_timeouts.receive_timeout,
            pool_timeout: @default_timeouts.pool_timeout,
            request_timeout: @default_timeouts.request_timeout,
            telemetry_metadata: %{}

  @doc """
  build a config. opts override application env, application env
  overrides defaults.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    env = Application.get_all_env(:openrouter_sdk)

    fields =
      [
        api_key: opt(opts, env, :api_key),
        base_url: opt(opts, env, :base_url) || @default_base_url,
        finch_name: opt(opts, env, :finch_name) || @default_finch_name,
        default_headers: opt(opts, env, :default_headers) || [],
        middleware: opt(opts, env, :middleware) || [],
        receive_timeout: opt(opts, env, :receive_timeout) || @default_timeouts.receive_timeout,
        pool_timeout: opt(opts, env, :pool_timeout) || @default_timeouts.pool_timeout,
        request_timeout: opt(opts, env, :request_timeout) || @default_timeouts.request_timeout,
        telemetry_metadata: opt(opts, env, :telemetry_metadata) || %{}
      ]

    struct!(__MODULE__, fields)
  end

  @doc "merge a keyword override into an existing config (used per-call)"
  @spec merge(t(), keyword()) :: t()
  def merge(%__MODULE__{} = base, []), do: base

  def merge(%__MODULE__{} = base, opts) do
    Enum.reduce(opts, base, fn
      {:headers, extra}, acc ->
        %{acc | default_headers: acc.default_headers ++ extra}

      {key, value}, acc when is_map_key(acc, key) ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
  end

  defp opt(opts, env, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Keyword.get(env, key)
    end
  end
end
