{ lib }:
rec {
  validName = name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_.-]*" name != null;
  match = repository: builtins.match "https://([^/:]+)(:443)?(/.*)" repository.url;
  host = repository: lib.toLower (builtins.elemAt (match repository) 0);
  path = repository: builtins.elemAt (match repository) 2;
  hosts = workspace: lib.unique (map host (builtins.attrValues workspace.resolvedRepositories));
  resolve =
    workspace:
    let
      legacy = workspace.repository;
      legacyName =
        if legacy.checkoutName != null then
          legacy.checkoutName
        else
          lib.removeSuffix ".git" (lib.last (lib.splitString "/" legacy.url));
      inputs = if legacy == null then workspace.repositories else { ${legacyName} = legacy; };
    in
    lib.mapAttrs (
      name: repository:
      repository
      // {
        checkoutName = if repository.checkoutName == null then name else repository.checkoutName;
      }
    ) inputs;
}
