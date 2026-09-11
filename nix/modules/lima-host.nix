{
  lib,
  modulesPath,
  pkgs,
  ...
}:
let
  installLimaBootstrapKey = pkgs.writeShellScript "seter-install-lima-bootstrap-key" ''
    set -euo pipefail

    cidata=/mnt/lima-cidata
    user=$(${pkgs.gawk}/bin/awk -F= '
      $1 == "LIMA_CIDATA_USER" {
        sub(/^[^=]*=/, "")
        gsub(/^"|"$/, "")
        print
        exit
      }
    ' "$cidata/lima.env")
    [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || {
      echo "seter: invalid Lima bootstrap user in cidata" >&2
      exit 1
    }

    ${pkgs.coreutils}/bin/install -d -m 0755 /run/seter-lima-ssh
    key=$(${pkgs.coreutils}/bin/mktemp /run/seter-lima-ssh/.key.XXXXXX)
    trap '${pkgs.coreutils}/bin/rm -f "$key"' EXIT
    ${pkgs.gawk}/bin/awk '
      match($0, /^([[:space:]]*)ssh-authorized-keys:/, m) { pattern="^" m[1] "[[:space:]]+-[[:space:]]+"; found=1; next }
      found && $0 !~ pattern { found=0; next }
      found && $0 ~ pattern { sub(pattern, ""); gsub("\"", ""); print }
    ' "$cidata/user-data" >"$key"
    # Do not truncate the working login key if cidata parsing fails during a
    # redeployment. Publish only a complete, validated public-key projection.
    projectedKeys=$(${pkgs.gawk}/bin/awk 'NF { count++ } END { print count + 0 }' "$key")
    if ! fingerprints=$(${pkgs.openssh}/bin/ssh-keygen -l -f "$key" 2>/dev/null); then
      echo "seter: invalid Lima bootstrap SSH key in cidata" >&2
      exit 1
    fi
    validatedKeys=$(printf '%s\n' "$fingerprints" | ${pkgs.gawk}/bin/awk 'NF { count++ } END { print count + 0 }')
    if [ "$projectedKeys" -eq 0 ] || [ "$validatedKeys" -ne "$projectedKeys" ]; then
      echo "seter: invalid Lima bootstrap SSH key projection from cidata" >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/chmod 0444 "$key"
    ${pkgs.coreutils}/bin/mv -fT "$key" "/run/seter-lima-ssh/$user"
  '';
  mountLimaExchange = pkgs.writeShellScript "seter-mount-lima-exchange" ''
    set -euo pipefail

    cidata=/mnt/lima-cidata
    mountPoint=/workspace/seter-exchange
    tag=$(${pkgs.gawk}/bin/awk '
      match($0, /^-[[:space:]]*\[([^,]+),[[:space:]]*\/workspace\/seter-exchange,[[:space:]]*virtiofs,/, m) {
        gsub(/[[:space:]]/, "", m[1])
        print m[1]
        exit
      }
    ' "$cidata/user-data")
    [[ $tag =~ ^[a-zA-Z0-9._-]+$ ]] || {
      echo "seter: missing or invalid Lima exchange-directory virtiofs tag in cidata" >&2
      exit 1
    }

    ${pkgs.coreutils}/bin/install -d -m 0755 "$mountPoint"
    if ! ${pkgs.util-linux}/bin/mountpoint -q "$mountPoint"; then
      ${pkgs.util-linux}/bin/mount -t virtiofs -o rw "$tag" "$mountPoint"
    fi

    source=$(${pkgs.util-linux}/bin/findmnt -n -o SOURCE --target "$mountPoint")
    fsType=$(${pkgs.util-linux}/bin/findmnt -n -o FSTYPE --target "$mountPoint")
    options=$(${pkgs.util-linux}/bin/findmnt -n -o OPTIONS --target "$mountPoint")
    [[ $source == "$tag" && $fsType == virtiofs && ,$options, == *,rw,* ]] || {
      echo "seter: $mountPoint must be the cidata-declared read-write virtiofs mount" >&2
      exit 1
    }
  '';
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  assertions = [
    {
      assertion = pkgs.stdenv.hostPlatform.system == "aarch64-linux";
      message = "seter.nixosModules.limaHost supports only aarch64-linux";
    }
  ];

  # nixos-lima creates the bootstrap user from Lima's cidata. It must remain
  # mutable across the first declarative deployment or remote SSH access is
  # lost before the consumer can take ownership of users.
  services.lima.enable = true;
  services.openssh.enable = true;
  # Declarative activation replaces nixos-lima's /etc key. Preserve a separate
  # root-controlled projection from the immutable cidata so macos-host can use
  # Lima's generated key immediately after activation and after cold boots.
  services.openssh.authorizedKeysInHomedir = false;
  services.openssh.authorizedKeysFiles = [ "/run/seter-lima-ssh/%u" ];
  users.mutableUsers = true;
  security.sudo.wheelNeedsPassword = false;

  # nixos-lima creates this public-key directory with mode 0700. sshd checks
  # /etc keys after dropping privileges and therefore needs to traverse it.
  # tmpfiles fixes subsequent boots; the activation script fixes the first
  # declarative switch, where the directory already exists.
  systemd.tmpfiles.rules = [ "d /etc/ssh/authorized_keys.d 0755 root root -" ];
  system.activationScripts.seterLimaAuthorizedKeysDirectory.text = ''
    ${pkgs.coreutils}/bin/mkdir -p /etc/ssh/authorized_keys.d
    ${pkgs.coreutils}/bin/chmod 0755 /etc/ssh/authorized_keys.d
    ${installLimaBootstrapKey}
  '';

  systemd.services.seter-lima-bootstrap-key = {
    description = "Project the Lima bootstrap SSH key from cidata";
    requires = [ "lima-init.service" ];
    after = [ "lima-init.service" ];
    before = [ "sshd.service" ];
    requiredBy = [ "sshd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = installLimaBootstrapKey;
    };
  };

  # Lima creates this mount from cidata during boot, but a declarative NixOS
  # switch removes the generated mount unit as obsolete. Re-establish the one
  # explicit exchange mount from the immutable cidata description so policy
  # review continues to edit the consumer-owned file after deployment.
  # switch-to-configuration consumes this restart request after obsolete
  # generated mount units have been stopped. Starting an active oneshot is
  # insufficient; explicitly restart it on every switch, even unchanged ones.
  system.activationScripts.seterLimaExchange.text = ''
    mkdir -p /run/nixos
    echo seter-lima-exchange.service >> /run/nixos/activation-restart-list
  '';

  systemd.services.seter-lima-exchange = {
    description = "Mount the Lima Client Exchange Directory";
    requires = [ "lima-init.service" ];
    after = [ "lima-init.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = mountLimaExchange;
    };
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [ "@wheel" ];
  };

  # ARM Workspaces use the validated nested QEMU/KVM path. Enabling the Host
  # here gives consumers one integration import while leaving its Registry,
  # Policy File, users, credentials, and resource choices consumer-owned.
  seter.host = {
    enable = lib.mkDefault true;
    runner.hypervisor = lib.mkDefault "qemu";
  };

  boot = {
    # limaHost is specifically the accepted nested-virtualization Host. Force
    # the validated LTS instead of relying only on the composed Host default.
    kernelPackages = lib.mkForce pkgs.linuxPackages_6_12;
    kernelParams = [ "console=tty0" ];
    loader.grub = {
      device = "nodev";
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
  };

  # These describe the partitions in the pinned bootstrap image. Deployment
  # switches the system generation in place; it neither formats nor replaces
  # Lima's persistent disk.
  fileSystems = {
    "/boot" = {
      device = lib.mkForce "/dev/vda1";
      fsType = "vfat";
    };
    "/" = {
      device = "/dev/disk/by-label/nixos";
      autoResize = true;
      fsType = "ext4";
      options = [
        "noatime"
        "nodiratime"
        "discard"
      ];
    };
  };

  environment.systemPackages = with pkgs; [
    gitMinimal
    nextvi
  ];
}
