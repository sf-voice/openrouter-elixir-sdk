defmodule OpenrouterSdk.Streaming do
  @moduledoc """
  shared sink semantics for `*_stream` apis.

  consumers can opt into three sinks via `:into`:

    * default (no `:into`) — `{:ok, stream}`, lazy `Stream`.
    * `:into` is a `pid` — events are forwarded as
      `{:openrouter_event, ref, event}`; returns `{:ok, ref}`.
    * `:into` is a `fun/2` — runs `Enum.reduce/3` for the consumer
      with `acc: opts[:acc] || []`; returns `{:ok, acc}`.

  the streaming function is passed as a thunk so we can decide
  whether to invoke it inline or inside a separate task — this
  matters because the underlying stream reads from the mailbox of
  whichever process opened it.
  """

  @type start_fn :: (-> {:ok, Enumerable.t()} | {:error, term()})

  @spec wrap(start_fn(), keyword()) ::
          {:ok, Enumerable.t() | reference() | term()} | {:error, term()}
  def wrap(start_fn, opts) when is_function(start_fn, 0) do
    case Keyword.get(opts, :into) do
      nil ->
        start_fn.()

      pid when is_pid(pid) ->
        forward_to_pid(start_fn, pid)

      fun when is_function(fun, 2) ->
        case start_fn.() do
          {:ok, stream} -> {:ok, Enum.reduce(stream, Keyword.get(opts, :acc, []), fun)}
          err -> err
        end
    end
  end

  defp forward_to_pid(start_fn, pid) do
    ref = make_ref()
    parent = self()

    Task.start(fn ->
      case start_fn.() do
        {:ok, stream} ->
          send(parent, {:openrouter_started, ref, :ok})

          Enum.each(stream, fn event ->
            send(pid, {:openrouter_event, ref, event})
          end)

          send(pid, {:openrouter_event, ref, :complete})

        {:error, error} ->
          send(parent, {:openrouter_started, ref, {:error, error}})
      end
    end)

    receive do
      {:openrouter_started, ^ref, :ok} -> {:ok, ref}
      {:openrouter_started, ^ref, {:error, error}} -> {:error, error}
    after
      30_000 -> {:error, :stream_start_timeout}
    end
  end
end
