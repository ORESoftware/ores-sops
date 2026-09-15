import "@typespec/json-schema";
using TypeSpec.JsonSchema;

namespace OresSops.PortableConfig;

@id("DeploymentEnvironment")
enum DeploymentEnvironment {
  dev: "dev",
  stage: "stage",
  prod: "prod",
}

@id("ExecutionProfile")
enum ExecutionProfile {
  local: "local",
  gha: "gha",
  ghaIndieWorker: "gha-indie-worker",
  test: "test",
}

@id("ConfigValueType")
enum ConfigValueType {
  string: "string",
  bool: "bool",
  integer: "integer",
  double: "double",
  json: "json",
  url: "url",
}

@id("ConfigSensitivity")
enum ConfigSensitivity {
  secret: "secret",
  nonSecret: "non_secret",
}

@id("DiagnosticVisibility")
enum DiagnosticVisibility {
  keyNameOnly: "key_name_only",
  metadataAllowed: "metadata_allowed",
}

@id("ConfigKeyPolicy")
model ConfigKeyPolicy {
  @pattern("^[A-Z_][A-Z0-9_]*$")
  key: string;
  valueType: ConfigValueType;
  sensitivity: ConfigSensitivity;
  required: boolean;
  environments: DeploymentEnvironment[];
  profiles: ExecutionProfile[];
  profileOverride: boolean;
  diagnosticVisibility: DiagnosticVisibility;
  owner?: string;
  provider?: string;
  deprecated?: boolean;
  replacementKey?: string;
}

@id("PortableConfigManifest")
model PortableConfigManifest {
  schema: "ores-sops.portable-config/v1";
  keys: ConfigKeyPolicy[];
}
