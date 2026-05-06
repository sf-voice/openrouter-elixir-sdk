defmodule OpenrouterSdk.BypassHelpers do
  @moduledoc false
  # small helpers for spinning up a bypass instance and pointing the
  # sdk at it.

  def setup_bypass(opts \\ []) do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}/api/v1"

    config_opts =
      [
        api_key: opts[:api_key] || "test-key",
        base_url: base_url,
        finch_name: OpenrouterSdk.TestFinch,
        receive_timeout: 5_000,
        request_timeout: 5_000,
        pool_timeout: 1_000
      ]

    {bypass, config_opts}
  end

  def sse_chunks(events) do
    Enum.map(events, fn
      :done -> "data: [DONE]\n\n"
      {:event, name, data} -> "event: #{name}\ndata: #{data}\n\n"
      {:data, data} -> "data: #{data}\n\n"
    end)
  end

  def stream_body(conn, chunks) do
    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(chunks, conn, fn chunk, c ->
      {:ok, c} = Plug.Conn.chunk(c, chunk)
      c
    end)
  end
end
