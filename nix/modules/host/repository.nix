{ lib, ... }:
{
  options = {
    url = lib.mkOption {
      type = lib.types.strMatching "https://([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])(:443)?/[^?#[:space:]]+";
      description = "Approved HTTPS Git repository URL.";
      example = "https://git.example/owner/project.git";
    };
    branch = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[^[:space:]]+");
      default = null;
      description = "Initial branch; null uses the remote default. Does not switch existing checkouts.";
    };
    checkoutName = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_.-]*");
      default = null;
      description = "Directory under /project; defaults to the repository key (URL basename for legacy repository).";
    };
    credential = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[a-zA-Z][a-zA-Z0-9_-]{0,62}");
      default = null;
      description = "Optional repository-scoped Authorization binding in the workspace's secrets.";
    };
  };
}
