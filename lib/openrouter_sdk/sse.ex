defmodule OpenrouterSdk.SSE do
  @moduledoc """
  incremental server-sent-events parser.

  pure functional: `feed(state, bytes) -> {events, new_state}`. the
  caller pumps bytes in (typically arriving from finch), and gets back
  whatever fully-formed events the parser could complete from the
  combined buffer. partial lines stay in `state.buffer`.

  understands:
    * `data:`, `event:`, `id:`, `retry:`
    * comment lines starting with `:`
    * crlf and lf line endings
    * multi-line `data:` (joined with `\\n`)
    * the openai-style `[DONE]` terminator (emitted as `:done`)
  """

  defmodule Event do
    @moduledoc "a single completed sse event (post-dispatch)"

    @type t :: %__MODULE__{
            event: String.t() | nil,
            id: String.t() | nil,
            data: String.t(),
            retry: non_neg_integer() | nil
          }

    defstruct event: nil, id: nil, data: "", retry: nil
  end

  @type state :: %{
          buffer: binary(),
          event: String.t() | nil,
          id: String.t() | nil,
          data: [String.t()],
          retry: non_neg_integer() | nil
        }

  @type emitted :: Event.t() | :done

  @doc "fresh parser state"
  @spec init() :: state()
  def init, do: %{buffer: "", event: nil, id: nil, data: [], retry: nil}

  @doc """
  feed bytes into the parser. returns `{events, new_state}` where
  `events` is the (possibly empty) list of newly completed events in
  arrival order.
  """
  @spec feed(state(), binary()) :: {[emitted()], state()}
  def feed(state, bytes) when is_binary(bytes) do
    {lines, rest} = split_lines(state.buffer <> bytes)
    state = %{state | buffer: rest}
    Enum.reduce(lines, {[], state}, &handle_line/2) |> finalize()
  end

  defp finalize({acc, state}), do: {Enum.reverse(acc), state}

  # blank line dispatches the accumulated event
  defp handle_line("", {acc, state}), do: dispatch(acc, state)

  # comment line — just an empty key, ignored per spec
  defp handle_line(":" <> _comment, {acc, state}), do: {acc, state}

  defp handle_line(line, {acc, state}) do
    case parse_field(line) do
      {"data", value} -> {acc, %{state | data: [value | state.data]}}
      {"event", value} -> {acc, %{state | event: value}}
      {"id", value} -> {acc, %{state | id: value}}
      {"retry", value} -> {acc, %{state | retry: parse_int(value)}}
      :ignore -> {acc, state}
    end
  end

  defp parse_field(line) do
    case :binary.split(line, ":") do
      [field, rest] -> {field, strip_leading_space(rest)}
      [field] -> {field, ""}
      _ -> :ignore
    end
  end

  defp strip_leading_space(" " <> rest), do: rest
  defp strip_leading_space(rest), do: rest

  # dispatch: if no data field was seen, just reset and continue
  defp dispatch(acc, %{data: []} = state), do: {acc, reset(state)}

  defp dispatch(acc, state) do
    data = state.data |> Enum.reverse() |> Enum.join("\n")

    cond do
      data == "[DONE]" ->
        {[:done | acc], reset(state)}

      true ->
        event = %Event{
          event: state.event,
          id: state.id,
          data: data,
          retry: state.retry
        }

        {[event | acc], reset(state)}
    end
  end

  defp reset(state), do: %{state | event: nil, id: nil, data: [], retry: nil}

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  # split buffer into complete lines + leftover. handles \r\n, \n, and
  # bare \r (treated as a line terminator per the spec).
  defp split_lines(binary), do: split_lines(binary, "", [])

  defp split_lines(<<>>, current, acc), do: {Enum.reverse(acc), current}

  defp split_lines(<<"\r\n", rest::binary>>, current, acc),
    do: split_lines(rest, "", [current | acc])

  defp split_lines(<<"\n", rest::binary>>, current, acc),
    do: split_lines(rest, "", [current | acc])

  defp split_lines(<<"\r", rest::binary>>, current, acc),
    do: split_lines(rest, "", [current | acc])

  defp split_lines(<<c::utf8, rest::binary>>, current, acc),
    do: split_lines(rest, current <> <<c::utf8>>, acc)

  defp split_lines(<<byte, rest::binary>>, current, acc),
    do: split_lines(rest, current <> <<byte>>, acc)
end
