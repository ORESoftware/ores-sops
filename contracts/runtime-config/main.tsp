import "@typespec/json-schema";
using TypeSpec.JsonSchema;

// Repository-root .ores-sops.toml consumer binding.
// This file and authored.schema.json are independent human-authored peer authorities.
// Portable secret/configuration metadata remains authoritative in ../portable-config/.
namespace OresSops.RuntimeConfig;

@id("OresSopsDiagnosticsMode")
enum OresSopsDiagnosticsMode {
  keyNameOnly: "key-name-only",
}

@id("OresSopsExecutionConfig")
model OresSopsExecutionConfig {
  fail_closed: boolean;
  persist_plaintext: boolean;
  diagnostics: OresSopsDiagnosticsMode;
}

@id("OresSopsRuntimeConfig")
model OresSopsRuntimeConfig {
  schema_version: 1;
  protocol: "ores.sops.consumer-config/v1";
  @minLength(1)
  environment: string;
  @minLength(1)
  profile: string;
  @minLength(1)
  portable_config_path: string;
  @minLength(1)
  ciphertext_path: string;
  execution: OresSopsExecutionConfig;
}
