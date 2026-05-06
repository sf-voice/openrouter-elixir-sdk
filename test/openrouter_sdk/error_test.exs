defmodule OpenrouterSdk.ErrorTest do
  use ExUnit.Case, async: true

  alias OpenrouterSdk.Error

  test "401 maps to :auth, non-retryable" do
    err = Error.classify(401, %{"error" => %{"message" => "bad key"}})
    assert err.kind == :auth
    refute err.retryable?
    assert err.message == "bad key"
  end

  test "402 maps to :payment_required, non-retryable" do
    err = Error.classify(402, %{})
    assert err.kind == :payment_required
    refute err.retryable?
  end

  test "429 maps to :rate_limit, retryable" do
    err = Error.classify(429, %{"error" => %{"code" => "rate_limited", "message" => "slow down"}})
    assert err.kind == :rate_limit
    assert err.retryable?
    assert err.code == "rate_limited"
  end

  test "5xx maps to :server, retryable" do
    err = Error.classify(503, "")
    assert err.kind == :server
    assert err.retryable?
  end

  test "transport reasons categorize correctly" do
    assert Error.transport(:timeout).kind == :timeout
    assert Error.transport({:closed, :something}).kind == :stream_disconnect
    assert Error.transport(:nxdomain).kind == :transport
    assert Error.transport(:nxdomain).retryable?
  end
end
