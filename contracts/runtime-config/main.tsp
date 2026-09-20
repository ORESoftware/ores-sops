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
  // SOPS consumers fail closed; this is a policy invariant, not an application toggle.
  fail_closed: true;
  // Decrypted plaintext is runtime-only and must never become persistent config state.
  persist_plaintext: false;
  diagnostics: OresSopsDiagnosticsMode;
}

@id("OresSopsRuntimeConfig")
model OresSopsRuntimeConfig {
  schema_version: 1;
  protocol: "ores.sops.consumer-config/v1";

  @pattern("^[a-z][a-z0-9_-]*$")
  environment: string;

  @pattern("^[a-z][a-z0-9_-]*$")
  profile: string;

  @pattern("^(?!/)(?!.*(?:^|/)\\.\\.(?:/|$)).+$")
  portable_config_path: string;

  @pattern("^(?!/)(?!.*(?:^|/)\\.\\.(?:/|$)).+$")
  ciphertext_path: string;

  execution: OresSopsExecutionConfig;
}
