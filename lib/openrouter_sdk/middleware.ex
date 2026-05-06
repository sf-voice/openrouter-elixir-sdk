defmodule OpenrouterSdk.Middleware do
  @moduledoc """
  extension hook for upstream consumers.

  this package intentionally ships zero retry / backoff / rotation
  policy. instead, consumers compose their own by implementing this
  behaviour and registering it in `:openrouter_sdk, :middleware`:

      config :openrouter_sdk,
        middleware: [
          {MyApp.Retry, max: 3, base: 200},
          {MyApp.Rotate, models: ["openai/gpt-4o", "anthropic/claude-sonnet-4-6"]}
        ]

  the `next` callback runs the rest of the pipeline (eventually
  reaching the finch call). a middleware that wants to retry simply
  re-invokes `next.(request)`; a rotator can swap fields on the
  request before passing it on.
  """

  alias OpenrouterSdk.Client.Request
  alias OpenrouterSdk.Error

  @type request :: Request.t()
  @type response :: {:ok, term()} | {:error, Error.t()}
  @type next :: (request() -> response())

  @callback call(request(), next(), opts :: keyword()) :: response()

  @doc """
  fold a list of middleware over the terminal `runner` function,
  producing a single function that runs the whole chain.
  """
  @spec build([module() | {module(), keyword()}], next()) :: next()
  def build(middleware, runner) when is_function(runner, 1) do
    Enum.reduce(Enum.reverse(middleware), runner, fn
      {mod, opts}, acc when is_atom(mod) and is_list(opts) ->
        fn req -> mod.call(req, acc, opts) end

      mod, acc when is_atom(mod) ->
        fn req -> mod.call(req, acc, []) end
    end)
  end
end
