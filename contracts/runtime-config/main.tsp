import "@typespec/json-schema";
using TypeSpec.JsonSchema;

// Repository-root .ores-sops.toml activation binding.
// This file and authored.schema.json are independent human-authored peer authorities.
// Secret metadata and portable configuration remain authoritative in ../portable-config/.
namespace OresSops.RuntimeConfig;

@id("OresSopsRuntimeConfig")
model OresSopsRuntimeConfig {
  schema: "ores.sops/config/v1";
  enabled: boolean;
}
