defmodule DependencyAdvisoryMitigationTest do
  @moduledoc """
  Locks the claims that `.audit_ignore` makes about the three open cowlib
  advisories. Each ignore entry there says why the advisory cannot reach imp;
  these tests fail if that stops being true, so the reasons cannot rot into
  prose.
  """

  use ExUnit.Case, async: true

  @vulnerable_functions [
    # EEF-CVE-2026-43969: unvalidated encoder, still unfixed in cowlib 2.20.0.
    {:cow_cookie, :cookie, 1},
    # EEF-CVE-2026-43971: fixed in cowlib 2.20.0, kept here as a floor.
    {:cow_link, :link, 1}
  ]

  test "no module in the imp application calls a cowlib function under advisory" do
    imports = application_imports(:imp)

    for mfa <- @vulnerable_functions do
      refute mfa in imports
    end

    refute Enum.any?(imports, fn {module, _function, _arity} ->
             module == :cow_http_struct_hd
           end)
  end

  test "cowboy carries the EEF-CVE-2026-43966 response-header mitigation" do
    _ = Application.load(:cowboy)
    version = :cowboy |> Application.spec(:vsn) |> List.to_string()

    assert Version.compare(version, "2.16.0") in [:eq, :gt],
           "cowboy #{version} predates the invalid_response_headers option"

    # Default options: cowboy must refuse a response header carrying CR or LF
    # rather than serialising cowlib's unescaped bytes onto the socket.
    assert :error_terminate =
             :cowboy_http.validate_response_headers(
               %{<<"x-test">> => <<"safe\r\nx-injected: true">>},
               %{}
             )

    assert :ok = :cowboy_http.validate_response_headers(%{<<"x-test">> => <<"safe">>}, %{})
  end

  test "Plug refuses the same bytes one layer above cowboy" do
    conn = Plug.Test.conn(:get, "/")

    for invalid <- ["safe\r\nx-injected: true", "safe\n", <<"safe", 0>>] do
      assert_raise Plug.Conn.InvalidHeaderError, fn ->
        Plug.Conn.put_resp_header(conn, "x-test", invalid)
      end
    end
  end

  defp application_imports(application) do
    {:ok, modules} = :application.get_key(application, :modules)

    Enum.flat_map(modules, fn module ->
      {:module, ^module} = Code.ensure_loaded(module)

      case :beam_lib.chunks(:code.which(module), [:imports]) do
        {:ok, {_module, [imports: imports]}} -> imports
        _unavailable -> []
      end
    end)
  end
end
