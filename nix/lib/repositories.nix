{ lib }:
rec {
  validName = name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_.-]*" name != null;
  match = repository: builtins.match "https://([^/:]+)(:443)?(/.*)" repository.url;
  host = repository: lib.toLower (builtins.elemAt (match repository) 0);
  path = repository: builtins.elemAt (match repository) 2;
  hosts = workspace: lib.unique (map host (builtins.attrValues workspace.resolvedRepositories));
  resolve =
    workspace:
    lib.mapAttrs (
      name: repository:
      repository
      // {
        checkoutName = if repository.checkoutName == null then name else repository.checkoutName;
      }
    ) workspace.repositories;
}
