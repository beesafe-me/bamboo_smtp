defmodule Bamboo.SMTPAdapter do
  @moduledoc """
  Sends email using SMTP.

  Use this adapter to send emails through SMTP. This adapter requires
  that some settings are set in the config. See the example section below.

  *Sensitive credentials should not be committed to source control and are best kept in environment variables.
  Using `{:system, "ENV_NAME"}` configuration is read from the named environment variable at runtime.*

  ## Example config

      # In config/config.exs, or config.prod.exs, etc.
      config :my_app, MyApp.Mailer,
        adapter: Bamboo.SMTPAdapter,
        server: "smtp.domain",
        hostname: "www.mydomain.com",
        port: 1025,
        username: "your.name@your.domain", # or {:system, "SMTP_USERNAME"}
        password: "pa55word", # or {:system, "SMTP_PASSWORD"}
        tls: :if_available, # can be `:always` or `:never`
        allowed_tls_versions: [:"tlsv1", :"tlsv1.1", :"tlsv1.2"],
        # or {":system", ALLOWED_TLS_VERSIONS"} w/ comma seprated values (e.g. "tlsv1.1,tlsv1.2")
        ssl: false, # can be `true`,
        retries: 1,
        no_mx_lookups: false, # can be `true`
        auth: :if_available # can be `always`. If your smtp relay requires authentication set it to `always`.

      # Define a Mailer. Maybe in lib/my_app/mailer.ex
      defmodule MyApp.Mailer do
        use Bamboo.Mailer, otp_app: :my_app
      end
  """

  @behaviour Bamboo.Adapter

  require Logger

  @required_configuration [:server, :port]
  @default_configuration %{
    tls: :if_available,
    ssl: :false,
    retries: 1,
    transport: :gen_smtp_client,
    auth: :if_available
  }
  @tls_versions ~w(tlsv1 tlsv1.1 tlsv1.2)

  defmodule SMTPError do
    @moduledoc false

    defexception [:message, :raw]

    def exception(raw = {reason, detail}) do
      message = """
      There was a problem sending the email through SMTP.

      The error is #{inspect(reason)}

      More detail below:

      #{inspect(detail)}
      """

      %SMTPError{message: message, raw: raw}
    end
  end

  @impl Bamboo.Adapter
  def deliver(email, config) do
    gen_smtp_config =
      config
      |> to_gen_smtp_server_config

    email
    |> Bamboo.Mailer.normalize_addresses
    |> to_gen_smtp_message
    |> config[:transport].send_blocking(gen_smtp_config)
    |> handle_response
  end

  @doc false
  @impl Bamboo.Adapter
  def handle_config(config) do
    config
    |> check_required_configuration
    |> put_default_configuration
  end

  @doc false
  @impl Bamboo.Adapter
  def supports_attachments?, do: true

  defp handle_response({:error, :no_credentials = reason}) do
    raise SMTPError, {reason, "Username and password were not provided for authentication."}
  end

  defp handle_response({:error, reason, detail}) do
    raise SMTPError, {reason, detail}
  end

  defp handle_response(response) do
    {:ok, response}
  end

  defp rfc822_encode(content) do
    "=?UTF-8?B?#{Base.encode64(content)}?="
  end

  defp aggregate_errors(config, key, errors) do
    config
    |> Map.fetch(key)
    |> build_error(key, errors)
  end

  defp apply_default_configuration({:ok, value}, _default, config) when value != nil do
    config
  end
  defp apply_default_configuration(_not_found_value, {key, default_value}, config) do
    Map.put_new(config, key, default_value)
  end

  defp body(email = %Bamboo.Email{}) do
    message =
      Mail.build_multipart()
      |> Mail.put_subject(email.subject || "")
      |> put_from(email.from)
      |> Mail.put_bcc(email.bcc)
      |> Mail.put_cc(email.cc)
      |> put_to(email.to)
      |> put_body(email.text_body, :put_text)
      |> put_body(email.html_body, :put_html)

    message =
      Enum.reduce(email.attachments, message, fn attachment, message ->
        Mail.put_attachment(message, {attachment.filename, attachment.data})
      end)

    Mail.Renderers.RFC2822.render(message)
  end

  defp put_to(m, addrs) when is_list(addrs) do
    Enum.reduce(addrs, m, fn a, m -> 
      put_to(m, a) 
    end)
  end

  defp put_to(m, {nil, address}), do: Mail.put_to(m, address)
  defp put_to(m, address), do: Mail.put_to(m, address)

  defp put_from(m, {nil, address}), do: Mail.put_from(m, address)
  defp put_from(m, address), do: Mail.put_from(m, address)

  defp build_error({:ok, value}, _key, errors) when value != nil, do: errors
  defp build_error(_not_found_value, key, errors) do
    ["Key #{key} is required for SMTP Adapter" | errors]
  end

  defp put_body(m, v, _callback) when v in [nil, ""], do: m

  defp put_body(m, v, callback) do
    apply(Mail, callback, [m, v])
  end

  defp check_required_configuration(config) do
    @required_configuration
    |> Enum.reduce([], &aggregate_errors(config, &1, &2))
    |> raise_on_missing_configuration(config)
  end

  defp format_email({nil, email}, _format), do: email
  defp format_email({name, email}, true), do: "#{rfc822_encode(name)} <#{email}>"
  defp format_email({_name, email}, false), do: email
  defp format_email(emails, format) when is_list(emails) do
    Enum.map(emails, &format_email(&1, format))
  end

  defp format_email(email, type, format \\ true) do
    email
    |> Bamboo.Formatter.format_email_address(type)
    |> format_email(format)
  end

  defp from_without_format(%Bamboo.Email{from: from}) do
    from
    |> format_email(:from, false)
  end

  defp put_default_configuration(config) do
    @default_configuration
    |> Enum.reduce(config, &put_default_configuration(&2, &1))
  end

  defp put_default_configuration(config, default = {key, _default_value}) do
    config
    |> Map.fetch(key)
    |> apply_default_configuration(default, config)
  end

  defp raise_on_missing_configuration([], config), do: config
  defp raise_on_missing_configuration(errors, config) do
    formatted_errors =
      errors
      |> Enum.map(&("* #{&1}"))
      |> Enum.join("\n")

    raise ArgumentError, """
    The following settings have not been found in your settings:

    #{formatted_errors}

    They are required to make the SMTP adapter work. Here you configuration:

    #{inspect config}
    """
  end

  defp to_without_format(email = %Bamboo.Email{}) do
    email
    |> Bamboo.Email.all_recipients
    |> format_email(:to, false)
  end

  defp to_gen_smtp_message(email = %Bamboo.Email{}) do
    {from_without_format(email), to_without_format(email), body(email)}
  end

  defp to_gen_smtp_server_config(config) do
    Enum.reduce(config, [], &to_gen_smtp_server_config/2)
  end

  defp to_gen_smtp_server_config({:server, value}, config) when is_binary(value) do
    [{:relay, value} | config]
  end
  defp to_gen_smtp_server_config({:username, value}, config) when is_binary(value) do
    [{:username, value} | config]
  end
  defp to_gen_smtp_server_config({:password, value}, config) when is_binary(value) do
    [{:password, value} | config]
  end
  defp to_gen_smtp_server_config({:tls, "if_available"}, config) do
    [{:tls, :if_available} | config]
  end
  defp to_gen_smtp_server_config({:tls, "always"}, config) do
    [{:tls, :always} | config]
  end
  defp to_gen_smtp_server_config({:tls, "never"}, config) do
    [{:tls, :never} | config]
  end
  defp to_gen_smtp_server_config({:tls, value}, config) when is_atom(value) do
    [{:tls, value} | config]
  end
  defp to_gen_smtp_server_config({:allowed_tls_versions, value}, config) when is_binary(value) do
    [{:tls_options, [{:versions, string_to_tls_versions(value)}]} | config]
  end
  defp to_gen_smtp_server_config({:allowed_tls_versions, value}, config) when is_list(value) do
    [{:tls_options, [{:versions, value}]} | config]
  end
  defp to_gen_smtp_server_config({:port, value}, config) when is_binary(value) do
    [{:port, String.to_integer(value)} | config]
  end
  defp to_gen_smtp_server_config({:port, value}, config) when is_integer(value) do
    [{:port, value} | config]
  end
  defp to_gen_smtp_server_config({:ssl, "true"}, config) do
    [{:ssl, true} | config]
  end
  defp to_gen_smtp_server_config({:ssl, "false"}, config) do
    [{:ssl, false} | config]
  end
  defp to_gen_smtp_server_config({:ssl, value}, config) when is_boolean(value) do
    [{:ssl, value} | config]
  end
  defp to_gen_smtp_server_config({:retries, value}, config) when is_binary(value) do
    [{:retries, String.to_integer(value)} | config]
  end
  defp to_gen_smtp_server_config({:retries, value}, config) when is_integer(value) do
    [{:retries, value} | config]
  end
  defp to_gen_smtp_server_config({:hostname, value}, config) when is_binary(value) do
    [{:hostname, value} | config]
  end
  defp to_gen_smtp_server_config({:no_mx_lookups, "true"}, config) do
    [{:no_mx_lookups, true} | config]
  end
  defp to_gen_smtp_server_config({:no_mx_lookups, "false"}, config) do
    [{:no_mx_lookups, false} | config]
  end
  defp to_gen_smtp_server_config({:no_mx_lookups, value}, config) when is_boolean(value) do
    [{:no_mx_lookups, value} | config]
  end
  defp to_gen_smtp_server_config({:auth, "if_available"}, config) do
    [{:auth, :if_available} | config]
  end
  defp to_gen_smtp_server_config({:auth, "always"}, config) do
    [{:auth, :always} | config]
  end
  defp to_gen_smtp_server_config({:auth, value}, config) when is_atom(value) do
    [{:auth, value} | config]
  end
  defp to_gen_smtp_server_config({conf, {:system, var}}, config) do
    to_gen_smtp_server_config({conf, System.get_env(var)}, config)
  end
  defp to_gen_smtp_server_config({_key, _value}, config) do
    config
  end

  defp string_to_tls_versions(version_string) do
    version_string
    |> String.split(",")
    |> Enum.filter(&(&1 in @tls_versions))
    |> Enum.map(&String.to_atom/1)
  end
end
