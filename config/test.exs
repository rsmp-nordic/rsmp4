# Test environment configuration
import Config

# Disable Swoosh API client in test environment (no external HTTP adapters needed)
config :swoosh, :api_client, false

