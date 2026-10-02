{ lib }:
rec {
  validName = name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_.-]*" name != null;
  match =
    repository:
    if repository.url == null then
      null
    else
      builtins.match "https://([^/:]+)(:443)?(/.*)" repository.url;
  host =
    repository:
    if match repository == null then "" else lib.toLower (builtins.elemAt (match repository) 0);
  path = repository: if match repository == null then "" else builtins.elemAt (match repository) 2;
  remote =
    workspace: lib.filterAttrs (_: repository: !repository.local) workspace.resolvedRepositories;
  hosts = workspace: lib.unique (map host (builtins.attrValues (remote workspace)));
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
