defmodule OpenrouterSdk.Client.Request do
  @moduledoc """
  internal request representation.

  shared by buffered and streaming calls. middleware sees this struct
  before it's serialized into a finch request.
  """

  @type method :: :get | :post | :put | :patch | :delete
  @type body ::
          nil
          | iodata()
          | {:json, term()}
          | {:multipart, list()}
          | {:stream, Enumerable.t()}

  @type t :: %__MODULE__{
          method: method(),
          path: String.t(),
          query: keyword() | map(),
          headers: [{String.t(), String.t()}],
          body: body(),
          accept: :json | :sse | :binary,
          opts: keyword()
        }

  defstruct method: :get,
            path: "/",
            query: [],
            headers: [],
            body: nil,
            accept: :json,
            opts: []
end
