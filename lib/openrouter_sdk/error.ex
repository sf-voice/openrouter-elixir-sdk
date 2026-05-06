defmodule OpenrouterSdk.Error do
  @moduledoc """
  uniform error struct returned by every public api function.

  `retryable?` is the primary signal consumer middleware should use to
  decide whether to back off and try again (or rotate to a different
  model/provider). we keep `body` around so callers can inspect the
  raw upstream payload when they need to.
  """

  @type kind ::
          :transport
          | :timeout
          | :auth
          | :rate_limit
          | :payment_required
          | :invalid_request
          | :server
          | :stream_disconnect
          | :decode

  @type t :: %__MODULE__{
          kind: kind(),
          status: non_neg_integer() | nil,
          code: String.t() | nil,
          message: String.t(),
          retryable?: boolean(),
          body: term()
        }

  defstruct kind: :transport,
            status: nil,
            code: nil,
            message: "",
            retryable?: false,
            body: nil

  @doc """
  classify an http response (status + decoded body) into an error struct.

  the status -> kind mapping follows the documented openrouter codes
  (400 invalid_request, 401 auth, 402 payment_required, 408 timeout,
  429 rate_limit, 5xx server). retry semantics default to: transient
  on timeouts / rate limits / server errors, permanent on auth, billing,
  validation.
  """
  @spec classify(non_neg_integer(), term()) :: t()
  def classify(status, body) when is_integer(status) do
    {kind, retryable?} = kind_for_status(status)
    {code, message} = extract_error_fields(body)

    %__MODULE__{
      kind: kind,
      status: status,
      code: code,
      message: message || default_message(kind, status),
      retryable?: retryable?,
      body: body
    }
  end

  @doc "build an error from a transport-layer failure (mint/finch reason term)"
  @spec transport(term()) :: t()
  def transport(reason) do
    %__MODULE__{
      kind: classify_transport(reason),
      message: "transport error: #{inspect(reason)}",
      retryable?: true,
      body: reason
    }
  end

  @doc "build an error for a stream that disconnected mid-flight"
  @spec stream_disconnect(term()) :: t()
  def stream_disconnect(reason) do
    %__MODULE__{
      kind: :stream_disconnect,
      message: "stream disconnected: #{inspect(reason)}",
      retryable?: true,
      body: reason
    }
  end

  @doc "build an error when a json body fails to decode"
  @spec decode(binary(), term()) :: t()
  def decode(body, reason) do
    %__MODULE__{
      kind: :decode,
      message: "failed to decode response: #{inspect(reason)}",
      retryable?: false,
      body: body
    }
  end

  defp kind_for_status(s) when s in 200..299, do: {:server, false}
  defp kind_for_status(400), do: {:invalid_request, false}
  defp kind_for_status(401), do: {:auth, false}
  defp kind_for_status(402), do: {:payment_required, false}
  defp kind_for_status(403), do: {:auth, false}
  defp kind_for_status(404), do: {:invalid_request, false}
  defp kind_for_status(408), do: {:timeout, true}
  defp kind_for_status(429), do: {:rate_limit, true}
  defp kind_for_status(s) when s >= 500, do: {:server, true}
  defp kind_for_status(_), do: {:invalid_request, false}

  defp classify_transport(:timeout), do: :timeout
  defp classify_transport({:closed, _}), do: :stream_disconnect
  defp classify_transport(_), do: :transport

  defp extract_error_fields(%{"error" => %{"code" => c, "message" => m}}), do: {to_string(c), m}
  defp extract_error_fields(%{"error" => %{"message" => m}}), do: {nil, m}
  defp extract_error_fields(%{"error" => msg}) when is_binary(msg), do: {nil, msg}
  defp extract_error_fields(%{"message" => m}), do: {nil, m}
  defp extract_error_fields(_), do: {nil, nil}

  defp default_message(:auth, _), do: "unauthorized"
  defp default_message(:rate_limit, _), do: "rate limited"
  defp default_message(:payment_required, _), do: "payment required (insufficient credits)"
  defp default_message(:timeout, _), do: "request timed out"
  defp default_message(:server, status), do: "server error (#{status})"
  defp default_message(:invalid_request, status), do: "invalid request (#{status})"
  defp default_message(kind, status), do: "#{kind} (#{status})"
end
