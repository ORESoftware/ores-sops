import "@typespec/json-schema";
using TypeSpec.JsonSchema;

namespace Ores.Sops;

@id("DiagnosticLevel")
enum DiagnosticLevel {
  info: "info",
  warn: "warn",
  error: "error",
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
  event: string;
  message: string;
  details: DiagnosticDetails;
}
