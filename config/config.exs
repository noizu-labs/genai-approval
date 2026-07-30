import Config

if config_env() == :test do
  config :genai_approval, GenAI.Approval.Test.Endpoint,
    secret_key_base: String.duplicate("a", 64),
    live_view: [signing_salt: "genai_approval_test_salt"],
    server: false

  config :phoenix, :json_library, Jason

  config :logger, level: :warning
end
