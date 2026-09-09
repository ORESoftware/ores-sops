import "@typespec/json-schema";
using TypeSpec.JsonSchema;

namespace Ores.Sops;

@id("DiagnosticLevel")
enum DiagnosticLevel {
  info: "info",
  warn: "warn",
  error: "error",
}

@id("DiagnosticEvent")
enum DiagnosticEvent {
  coreMissing: "core_missing",
  configMissing: "config_missing",
  dependencyMissing: "dependency_missing",
  argvAdmissionRejected: "argv_admission_rejected",
  environmentConflict: "environment_conflict",
  requiredEnvMissing: "required_env_missing",
  invalidEnvironment: "invalid_environment",
  commandStarted: "command_started",
  commandCompleted: "command_completed",
  commandFailed: "command_failed",
}

@id("DiagnosticDetails")
model DiagnosticDetails {
  command: string;
  profile: string;
  key: string;
  exitCode: int32;
}

@id("OresSopsDiagnostic")
model OresSopsDiagnostic {
  schema: "ores.sops/diagnostic/v1";
  level: DiagnosticLevel;
  component: "ores-sops";
  event: DiagnosticEvent;
  message: string;
  details: DiagnosticDetails;
}
