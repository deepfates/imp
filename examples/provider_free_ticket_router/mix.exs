defmodule ImpProviderFreeTicketRouter.MixProject do
  use Mix.Project

  def project do
    [
      app: :imp_provider_free_ticket_router,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [{:imp, path: System.get_env("IMP_PATH", "../..")}]
    ]
  end
end
