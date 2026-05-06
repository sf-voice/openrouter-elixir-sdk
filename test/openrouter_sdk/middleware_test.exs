defmodule OpenrouterSdk.MiddlewareTest do
  use ExUnit.Case, async: true

  alias OpenrouterSdk.Middleware

  defmodule Tagger do
    @behaviour OpenrouterSdk.Middleware
    @impl true
    def call(req, next, opts) do
      tag = Keyword.fetch!(opts, :tag)
      send(self(), {:before, tag})
      result = next.(req)
      send(self(), {:after, tag, result})
      result
    end
  end

  test "build/2 composes middleware in order — outer wraps inner" do
    runner = fn _req -> {:ok, :inner} end
    chain = Middleware.build([{Tagger, tag: :a}, {Tagger, tag: :b}], runner)

    chain.(:request)

    assert_received {:before, :a}
    assert_received {:before, :b}
    assert_received {:after, :b, {:ok, :inner}}
    assert_received {:after, :a, {:ok, :inner}}
  end

  test "build/2 with no middleware returns the runner unchanged" do
    runner = fn _ -> {:ok, :raw} end
    assert Middleware.build([], runner).(:r) == {:ok, :raw}
  end
end
