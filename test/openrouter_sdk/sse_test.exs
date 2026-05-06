defmodule OpenrouterSdk.SSETest do
  use ExUnit.Case, async: true

  alias OpenrouterSdk.SSE
  alias OpenrouterSdk.SSE.Event

  test "parses a single complete event" do
    {events, _state} = SSE.feed(SSE.init(), "data: hello\n\n")
    assert events == [%Event{data: "hello"}]
  end

  test "joins multi-line data fields with newline" do
    {events, _} = SSE.feed(SSE.init(), "data: line1\ndata: line2\n\n")
    assert [%Event{data: "line1\nline2"}] = events
  end

  test "captures event and id fields" do
    chunk = "event: message_delta\nid: msg_1\ndata: {}\n\n"
    {events, _} = SSE.feed(SSE.init(), chunk)
    assert [%Event{event: "message_delta", id: "msg_1", data: "{}"}] = events
  end

  test "ignores comment lines" do
    {events, _} = SSE.feed(SSE.init(), ": ping\n: another\ndata: ok\n\n")
    assert [%Event{data: "ok"}] = events
  end

  test "emits :done sentinel for [DONE]" do
    {events, _} = SSE.feed(SSE.init(), "data: [DONE]\n\n")
    assert events == [:done]
  end

  test "buffers across feed boundaries" do
    {events1, state1} = SSE.feed(SSE.init(), "data: hel")
    assert events1 == []

    {events2, state2} = SSE.feed(state1, "lo\n")
    assert events2 == []

    {events3, _state3} = SSE.feed(state2, "\n")
    assert [%Event{data: "hello"}] = events3
  end

  test "handles crlf line endings" do
    {events, _} = SSE.feed(SSE.init(), "data: x\r\n\r\n")
    assert [%Event{data: "x"}] = events
  end

  test "multiple events in one feed" do
    chunk = "data: a\n\ndata: b\n\ndata: [DONE]\n\n"
    {events, _} = SSE.feed(SSE.init(), chunk)
    assert [%Event{data: "a"}, %Event{data: "b"}, :done] = events
  end
end
