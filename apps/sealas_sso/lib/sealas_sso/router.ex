defmodule SealasSso.Router do
  use SealasSso, :router
  alias Plug.Conn

  @doc "Minimum request time in µs"
  @minimum_request_time 200_000

  @doc """
  Default SSO pipeline: accept requests in JSON format
  All requests to SSO are delayed to take roughly @minimum_request_time to prevent timing attacks.
  """
  pipeline :api do
    plug :accepts, ["json"]
    plug :request_timer
  end

  @doc """
  Pipeline for restricted routes, checks access token
  """
  pipeline :auth do
    plug :check_token
  end

  scope "/", SealasSso do
    pipe_through :api

    get  "/auth", AuthController, :index
    post "/registration", RegistrationController, :create
  end

  scope "/user", SealasSso do
    pipe_through :api
    pipe_through :auth

    resources "/", UserController
  end

  @doc """
  Registers a function to check time used to handle request.
  Subtracts time taken from @minimum_request_time and waits for $result ms
  """
  @spec request_timer(Plug.Conn.t, any) :: Plug.Conn.t
  def request_timer(conn, _options) do
    time = Time.utc_now()

    Conn.register_before_send(conn, fn conn ->
      diff = Time.diff(Time.utc_now(), time, :microsecond)

      if diff < @minimum_request_time, do: :timer.sleep round((@minimum_request_time - diff)/1000)
      conn
    end)
  end

  @doc """
  Checks authentication token from authorization header.

  If this fails, send 401 with message "error": "auth_fail" as JSON
  """
  @spec check_token(Plug.Conn.t, any) :: Plug.Conn.t
  def check_token(conn, _options) do
    token = get_req_header(conn, "authorization")

    case decrypt_token(List.first(token)) do
      {:error} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:unauthorized, "{\"error\": \"auth_fail\"}")
        |> halt
      _ ->
        conn
    end
  end

  @doc """
  Decrypt an authentication token

  Format "bearer: tokengoeshere" will be accepted and parsed out.
  """
  @spec decrypt_token(String.t) :: {:ok, String.t} | {:error}
  def decrypt_token(auth_token) when is_binary(auth_token) do
    auth_token = List.last(Regex.run(~r/(bearer\: )?(.+)/, auth_token))

    key = Application.get_env(:sealas_sso, SealasSso.Endpoint)[:token_key]

    jwk = %{"kty" => "oct", "k" => :base64url.encode(key)}

    case JOSE.JWT.verify(jwk, {%{alg: :jose_jws_alg_hmac}, auth_token}) do
      {true, token, _signature} ->
        {:ok, token}
      _ ->
        {:error}
    end
  end

  @spec decrypt_token(nil) :: {:error}
  def decrypt_token(_) do
    {:error}
  end
end
