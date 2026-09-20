import "@typespec/json-schema";
using TypeSpec.JsonSchema;

namespace OresSops.ConsumerConfig;

enum DeploymentEnvironment {
  dev,
  stage,
  prod,
}

enum ExecutionProfile {
  local,
  gha,
  `gha-indie-worker`: "gha-indie-worker",
  test,
}

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
  portable_config_path: string;
  ciphertext_path: string;
  execution: ExecutionSafety;
}
