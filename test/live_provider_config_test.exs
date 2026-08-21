defmodule LiveProviderConfigTest do
  use ExUnit.Case, async: false

  @provider_envs [
    "IMP_LIVE_PROVIDER",
    "IMP_LIVE_MODEL",
    "OPENAI_API_KEY",
    "OPENAI_MODEL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_MODEL",
    "GEMINI_API_KEY",
    "GEMINI_MODEL",
    "OPENROUTER_API_KEY",
    "OPENROUTER_MODEL"
  ]

  setup do
    original = Map.new(@provider_envs, &{&1, System.get_env(&1)})
    Enum.each(@provider_envs, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "discovers OpenRouter when it is the available live provider" do
    System.put_env("OPENROUTER_API_KEY", "test-openrouter-key")
    System.put_env("OPENROUTER_MODEL", "openai/gpt-test")

    assert Imp.Test.LiveProvider.config!() == %{
             provider: "openrouter",
             model: "openai/gpt-test",
             api_key: "test-openrouter-key"
           }
  end

  test "an explicit provider selection takes precedence over discovery" do
    System.put_env("IMP_LIVE_PROVIDER", "anthropic")
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")
    System.put_env("ANTHROPIC_MODEL", "claude-test")
    System.put_env("OPENROUTER_API_KEY", "test-openrouter-key")
    System.put_env("OPENROUTER_MODEL", "openai/gpt-test")

    assert Imp.Test.LiveProvider.config!() == %{
             provider: "anthropic",
             model: "claude-test",
             api_key: "test-anthropic-key"
           }
  end
end
