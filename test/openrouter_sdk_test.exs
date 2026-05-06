defmodule OpenrouterSdkTest do
  use ExUnit.Case, async: true

  test "facade exposes the expected delegated functions" do
    exports = OpenrouterSdk.__info__(:functions) |> MapSet.new()

    for fun <- ~w(chat chat_stream messages messages_stream embeddings speech transcription)a do
      assert MapSet.member?(exports, {fun, 1})
      assert MapSet.member?(exports, {fun, 2})
    end

    assert MapSet.member?(exports, {:models, 0})
    assert MapSet.member?(exports, {:models, 1})
  end
end
