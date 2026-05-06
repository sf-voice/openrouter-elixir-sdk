defmodule OpenrouterSdk.Client do
  @moduledoc """
  finch wrapper. two paths:

    * `request/2` — buffered. body collected, json decoded.
    * `stream/2` — sse. returns a lazy `Stream` that yields parsed
      events; consumers can also opt into pid / fun delivery via
      the `:into` option (see `OpenrouterSdk.Api.*` for usage).

  middleware wraps both paths so retry / rotation policies see every
  request including streams. for streams the middleware sees the
  initial `:ok | :error` decision (i.e. whether the stream started)
  but does not see the per-chunk events — those flow directly to the
  consumer's stream.
  """

  alias OpenrouterSdk.{Auth, Config, Error, JSON, Middleware, SSE, Telemetry}
  alias OpenrouterSdk.Client.Request

  @sse_chunk_msg :openrouter_sdk_sse_chunk

  @doc "execute a buffered request. returns {:ok, decoded} | {:error, error}"
  @spec request(Request.t(), Config.t()) :: {:ok, term()} | {:error, Error.t()}
  def request(%Request{} = req, %Config{} = config) do
    runner = fn req -> do_buffered(req, config) end
    chain = Middleware.build(config.middleware, runner)

    Telemetry.span(
      [:request],
      Map.merge(config.telemetry_metadata, %{method: req.method, path: req.path}),
      fn ->
        result = with_auth(req, config, chain)
        {result, %{result: tag(result)}}
      end
    )
  end

  @doc """
  execute a streaming request. returns `{:ok, stream}` where `stream`
  is a lazy `Stream` of `:done | %SSE.Event{} | {:raw, bytes}` (the
  shape depends on opts the api module passes via `req.opts`).

  the stream is only safe to consume from the process that calls this
  function (it reads from that process mailbox). use `Stream.run/1`,
  `Enum.to_list/1`, or pipe through `Stream.map/2` etc.
  """
  @spec stream(Request.t(), Config.t()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(%Request{} = req, %Config{} = config) do
    runner = fn req -> start_stream(req, config) end
    chain = Middleware.build(config.middleware, runner)
    with_auth(req, config, chain)
  end

  # -- buffered path --------------------------------------------------

  defp do_buffered(req, config) do
    finch_req = build_finch_request(req, config)

    case Finch.request(finch_req, config.finch_name,
           receive_timeout: config.receive_timeout,
           pool_timeout: config.pool_timeout,
           request_timeout: config.request_timeout
         ) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        decode_body(req, body)

      {:ok, %Finch.Response{status: status, body: body}} ->
        decoded = maybe_decode(body)
        {:error, Error.classify(status, decoded)}

      {:error, reason} ->
        {:error, Error.transport(reason)}
    end
  end

  defp decode_body(%Request{accept: :binary}, body), do: {:ok, body}

  defp decode_body(%Request{accept: :json}, "" = _body), do: {:ok, %{}}

  defp decode_body(%Request{accept: :json}, body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, Error.decode(body, reason)}
    end
  end

  defp decode_body(_req, body), do: {:ok, body}

  defp maybe_decode(""), do: %{}

  defp maybe_decode(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  # -- streaming path -------------------------------------------------

  defp start_stream(req, config) do
    finch_req = build_finch_request(req, config)
    parent = self()
    ref = make_ref()

    {:ok, ack_pid} =
      Task.start(fn ->
        send(parent, {ref, :started, self()})

        receive do
          {^ref, :go} -> :ok
          {^ref, :stop} -> exit(:shutdown)
        after
          5_000 -> exit(:timeout)
        end

        result =
          Finch.stream(
            finch_req,
            config.finch_name,
            {:headers_pending, ref, parent},
            &handle_stream_chunk/2,
            receive_timeout: config.receive_timeout,
            pool_timeout: config.pool_timeout,
            request_timeout: config.request_timeout
          )

        send(parent, {ref, :finished, result})
      end)

    receive do
      {^ref, :started, ^ack_pid} -> :ok
    after
      1_000 ->
        Process.exit(ack_pid, :kill)
        :ok
    end

    send(ack_pid, {ref, :go})

    case await_headers(ref) do
      {:ok, _status} ->
        {:ok, build_stream(ref, ack_pid, req)}

      {:error, %Error{} = error} ->
        send(ack_pid, {ref, :stop})
        {:error, error}
    end
  end

  # handler used by Finch.stream — accumulator carries the parser
  # state once headers are in.
  defp handle_stream_chunk({:status, status}, {:headers_pending, ref, parent}) do
    {:status, status, ref, parent}
  end

  defp handle_stream_chunk({:headers, headers}, {:status, status, ref, parent}) do
    send(parent, {ref, :headers, status, headers})
    {:body, status, ref, parent}
  end

  defp handle_stream_chunk({:data, _bytes}, {:status, status, ref, parent} = acc)
       when status >= 400 do
    # error path — should not normally hit because headers come first,
    # but handle the edge.
    _ = acc
    send(parent, {ref, :error, status})
    acc
  end

  defp handle_stream_chunk({:data, bytes}, {:body, status, ref, parent})
       when status in 200..299 do
    send(parent, {ref, @sse_chunk_msg, bytes})
    {:body, status, ref, parent}
  end

  defp handle_stream_chunk({:data, bytes}, {:body, status, ref, parent}) do
    send(parent, {ref, :error_body, status, bytes})
    {:body, status, ref, parent}
  end

  defp handle_stream_chunk({:trailers, _}, acc), do: acc

  defp await_headers(ref) do
    receive do
      {^ref, :headers, status, _headers} when status in 200..299 ->
        {:ok, status}

      {^ref, :headers, status, _headers} ->
        body = drain_error_body(ref)
        decoded = maybe_decode(body)
        {:error, Error.classify(status, decoded)}

      {^ref, :finished, {:error, reason}} ->
        {:error, Error.transport(reason)}
    after
      30_000 ->
        {:error,
         %Error{
           kind: :timeout,
           message: "timed out waiting for response headers",
           retryable?: true
         }}
    end
  end

  defp drain_error_body(ref, acc \\ "") do
    receive do
      {^ref, :error_body, _status, bytes} -> drain_error_body(ref, acc <> bytes)
      {^ref, :finished, _} -> acc
    after
      2_000 -> acc
    end
  end

  defp build_stream(ref, _task_pid, req) do
    decode = Keyword.get(req.opts, :decode, true)
    raw = Keyword.get(req.opts, :raw, false)
    transform = Keyword.get(req.opts, :transform)

    Stream.resource(
      fn -> {SSE.init(), false, ref} end,
      fn
        {_state, true, _ref} = acc ->
          {:halt, acc}

        {state, false, ref} = acc ->
          receive do
            {^ref, @sse_chunk_msg, bytes} ->
              {events, new_state} = SSE.feed(state, bytes)
              emit = events |> maybe_decode_events(decode, raw) |> maybe_transform(transform)
              {emit, {new_state, false, ref}}

            {^ref, :finished, _} ->
              {:halt, acc}

            {^ref, :error, _status} ->
              {:halt, acc}
          after
            120_000 -> {:halt, acc}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp maybe_decode_events(events, false, _raw), do: events
  defp maybe_decode_events(events, true, true), do: events

  defp maybe_decode_events(events, true, false) do
    Enum.map(events, fn
      :done -> :done
      %SSE.Event{data: data} = ev -> decode_event(ev, data)
    end)
  end

  defp decode_event(ev, data) do
    case JSON.decode(data) do
      {:ok, decoded} -> {ev.event || :data, decoded}
      _ -> {ev.event || :data, data}
    end
  end

  defp maybe_transform(events, nil), do: events

  defp maybe_transform(events, fun) when is_function(fun, 1) do
    Enum.map(events, fun)
  end

  # -- common ---------------------------------------------------------

  defp with_auth(%Request{path: "/auth/keys"} = req, _config, chain) do
    # the oauth exchange endpoint is unauthenticated — skip header build
    chain.(req)
  end

  defp with_auth(req, config, chain) do
    case Auth.headers(config) do
      {:ok, auth_headers} ->
        chain.(%{req | headers: auth_headers ++ req.headers})

      {:error, %Error{}} = err ->
        err
    end
  end

  defp build_finch_request(%Request{} = req, %Config{} = config) do
    url = build_url(config.base_url, req.path, req.query)
    headers = build_headers(req, config)
    {body, headers} = build_body(req.body, headers)

    Finch.build(req.method, url, headers, body)
  end

  defp build_url(base, path, query) do
    base = String.trim_trailing(base, "/")
    path = if String.starts_with?(path, "/"), do: path, else: "/" <> path
    encode_query(base <> path, query)
  end

  defp encode_query(url, []) when is_list([]), do: url
  defp encode_query(url, query) when query == [] or query == %{}, do: url

  defp encode_query(url, query) do
    qs = URI.encode_query(query)
    if qs == "", do: url, else: url <> "?" <> qs
  end

  defp build_headers(req, config) do
    accept_header =
      case req.accept do
        :sse -> [{"accept", "text/event-stream"}]
        :json -> [{"accept", "application/json"}]
        :binary -> []
      end

    user_agent = [{"user-agent", "openrouter_sdk-elixir/#{version()}"}]

    user_agent ++ config.default_headers ++ req.headers ++ accept_header
  end

  defp build_body(nil, headers), do: {nil, headers}

  defp build_body({:json, term}, headers) do
    body = JSON.encode!(term)
    {body, [{"content-type", "application/json"} | headers]}
  end

  defp build_body({:multipart, parts}, headers) do
    boundary =
      :crypto.strong_rand_bytes(16)
      |> Base.url_encode64(padding: false)

    body = encode_multipart(parts, boundary)

    {body,
     [
       {"content-type", "multipart/form-data; boundary=" <> boundary},
       {"content-length", Integer.to_string(IO.iodata_length(body))} | headers
     ]}
  end

  defp build_body(iodata, headers), do: {iodata, headers}

  # minimal multipart encoder. supports {:file, name, filename, content_type, binary}
  # and {:field, name, value}.
  defp encode_multipart(parts, boundary) do
    body =
      Enum.map(parts, fn
        {:field, name, value} ->
          [
            "--",
            boundary,
            "\r\n",
            ~s(content-disposition: form-data; name="),
            to_string(name),
            ~s("\r\n\r\n),
            to_string(value),
            "\r\n"
          ]

        {:file, name, filename, content_type, binary} ->
          [
            "--",
            boundary,
            "\r\n",
            ~s(content-disposition: form-data; name="),
            to_string(name),
            ~s("; filename="),
            filename,
            ~s("\r\n),
            "content-type: ",
            content_type,
            "\r\n\r\n",
            binary,
            "\r\n"
          ]
      end)

    [body, "--", boundary, "--\r\n"]
  end

  defp tag({:ok, _}), do: :ok
  defp tag({:error, _}), do: :error

  defp version do
    case :application.get_key(:openrouter_sdk, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
