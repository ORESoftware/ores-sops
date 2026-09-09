import "@typespec/json-schema";
using TypeSpec.JsonSchema;

namespace OresSops.GitHubActions;

@id("EnvironmentName")
enum EnvironmentName {
  dev: "dev",
  stage: "stage",
  prod: "prod",
}

@id("GitHubSource")
enum GitHubSource {
  environmentSecret: "github_environment_secret",
  repositorySecret: "github_repository_secret",
  organizationSecret: "github_organization_secret",
  environmentVariable: "github_environment_variable",
  repositoryVariable: "github_repository_variable",
  organizationVariable: "github_organization_variable",
}

@id("ResolutionSource")
enum ResolutionSource {
  envEnc: "env_enc",
  githubFallback: "github_fallback",
}

@id("ConfigDecision")
model ConfigDecision {
  key: string;
  resolution: ResolutionSource;
  githubSource?: GitHubSource;
}

@id("GitHubOnlyObservation")
model GitHubOnlyObservation {
  key: string;
  githubSource: GitHubSource;
  reason: "missing_from_env_enc";
}

@id("GitHubActionsReconciliationReceipt")
model GitHubActionsReconciliationReceipt {
  schema: "ores-sops.github-actions-reconciliation/v1";
  repository: string;
  environment: EnvironmentName;
  authoritativePath: string;
  decisions: ConfigDecision[];
  observations: GitHubOnlyObservation[];
}
