import "@typespec/json-schema";
using TypeSpec.JsonSchema;

namespace OresSops.ConsumerConfig;

@id("DeploymentEnvironment")
enum DeploymentEnvironment {
  dev,
  stage,
  prod,
}

@id("ExecutionProfile")
enum ExecutionProfile {
  local,
  gha,
  `gha-indie-worker`: "gha-indie-worker",
  test,
}

@id("ExecutionSafety")
model ExecutionSafety {
  fail_closed: true;
  persist_plaintext: false;
  diagnostics: "key-name-only";
}

@id("OresSopsConsumerConfigFile")
model OresSopsConsumerConfigFile {
  schema_version: 1;
  protocol: "ores.sops.consumer-config/v1";
  environment: DeploymentEnvironment;
  profile: ExecutionProfile;

  // Canonical repository-relative paths only. Consumers must not read outside the repo.
  @pattern("^(?!/)(?!.*(?:^|/)\\.\\.(?:/|$)).+$")
  portable_config_path: string;

  @pattern("^(?!/)(?!.*(?:^|/)\\.\\.(?:/|$)).+$")
  ciphertext_path: string;

  execution: ExecutionSafety;
}
