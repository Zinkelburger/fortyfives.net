defmodule Website45sV3.HTTPClient do
  @moduledoc """
  Form POSTs to third parties (Cloudflare siteverify, Google's token
  endpoint). Callers take the client module from config so tests can swap in
  a stub implementing `post/4`.
  """

  @doc """
  POSTs a form body and returns `{:ok, status, body}` or `{:error, reason}`.
  The pool checkout, the whole request and the response wait are all bounded,
  so a slow or unreachable host cannot hold a request process indefinitely.
  """
  def post(url, headers, body, timeout_ms) do
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Website45sV3.Finch,
           pool_timeout: timeout_ms,
           request_timeout: timeout_ms,
           receive_timeout: timeout_ms
         ) do
      {:ok, %Finch.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  URL-encodes `params` and POSTs them with `client`.
  """
  def post_form(client, url, params, timeout_ms) do
    headers = [{"content-type", "application/x-www-form-urlencoded"}]
    client.post(url, headers, URI.encode_query(params), timeout_ms)
  end
end
