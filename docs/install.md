# Tutorial: Install and configure NixOS for bitcoinix on a dedicated machine

> [!NOTE]
> This document is inherited from nix-bitcoin, the predecessor project. It is a work in progress and may be outdated.

> [!WARNING]
> This documentation may be outdated or contain installation steps that do not work with
> bitcoinix yet.
> Please report problems at <https://github.com/bitcoinix/bitcoinix/issues>.

This tutorial describes how to manage your Bitcoin node comfortably from your personal computer: you keep the node configuration in a Nix flake and deploy it over SSH with `nixos-rebuild` or [Colmena](https://colmena.cli.rs/).
The deployment tool [krops](https://github.com/krebs/krops) is described as a legacy alternative.
However, bitcoinix is agnostic to the deployment method and can be used with different or without such tools (see [examples](https://github.com/bitcoinix/bitcoinix/blob/master/examples/README.md)).

## 0. Preparation

1. Find a machine to deploy bitcoinix on (see [hardware.md](hardware.md)).

2. Optional: Make sure you have the latest firmware for your system (BIOS, microcode updates).

3. Optional: Disable Simultaneous Multi-Threading (SMT) in the BIOS

    Researchers recommend disabling (SMT), also known as Hyper-Threading Technology in the Intel® world to significantly reduce the impact of speculative execution-based attacks (https://mdsattacks.com/).

## 1. NixOS installation

This is borrowed from the [NixOS manual](https://nixos.org/nixos/manual/index.html#ch-installation). Look there for more information.

1. Obtain the latest [NixOS](https://nixos.org/download/). For example:

    ```
    wget https://releases.nixos.org/nixos/26.05/nixos-26.05.12707.718f670e8453/nixos-minimal-26.05.12707.718f670e8453-x86_64-linux.iso
    # output: 12f093ce7bf7e9747c67730ee3cc7b22713912382e8d3d6f27ef6b19afd8c800
    sha256sum nixos-minimal-26.05.12707.718f670e8453-x86_64-linux.iso
    ```
    Alternatively you can build NixOS from source by following the instructions at https://nixos.org/nixos/manual/index.html#sec-building-cd.

2. Write the NixOS ISO to install media (USB/CD). For example:

    ```
    cp nixos-minimal-26.05.12707.718f670e8453-x86_64-linux.iso /dev/sdX
    ```

    Replace /dev/sdX with the correct device name. You can find this using `sudo fdisk -l`

3. Boot the system and become root

    ```
    sudo -i
    ```

    You will have to find out if your hardware uses UEFI or Legacy Boot for the next step. You can do that, for example, by executing

    ```
    ls /sys/firmware/efi
    ```

    If the file exists you should continue the installation for UEFI otherwise for Legacy Boot.

4. Option 1: Partition and format for UEFI

    ```
    parted /dev/sda -- mklabel gpt
    parted /dev/sda -- mkpart primary 512MiB -8GiB
    parted /dev/sda -- mkpart primary linux-swap -8GiB 100%
    parted /dev/sda -- mkpart ESP fat32 1MiB 512MiB
    parted /dev/sda -- set 3 boot on
    mkfs.ext4 -L nixos /dev/sda1
    mkswap -L swap /dev/sda2
    mkfs.fat -F 32 -n boot /dev/sda3
    mount /dev/disk/by-label/nixos /mnt
    mkdir -p /mnt/boot
    mount /dev/disk/by-label/boot /mnt/boot
    swapon /dev/sda2
    ```

4. Option 2: Partition and format for Legacy Boot (MBR)

    ```
    parted /dev/sda -- mklabel msdos
    parted /dev/sda -- mkpart primary 1MiB -8GiB
    parted /dev/sda -- mkpart primary linux-swap -8GiB 100%
    mkfs.ext4 -L nixos /dev/sda1
    mkswap -L swap /dev/sda2
    mount /dev/disk/by-label/nixos /mnt
    swapon /dev/sda2
    ```

4. Option 3: Set up encrypted partitions:

    Follow the guide at https://gist.github.com/martijnvermaat/76f2e24d0239470dd71050358b4d5134.

5. Generate NixOS config

    ```
    nixos-generate-config --root /mnt
    nano /mnt/etc/nixos/configuration.nix
    ```

    We now need to adjust the configuration to make sure that we can SSH into the system and that it boots correctly. We add some lines to set `services.openssh` such that the configuration looks as follows:

    ```
    { config, pkgs, ... }:

    {
      imports = [
        ...
      ];

      # Enable the OpenSSH server.
      services.openssh = {
        enable = true;
        permitRootLogin = "yes";
      };

      # The rest of the file contains default options and hints.
    }
    ```

    Now we open `hardware-configuration.nix`

    ```
    nano /mnt/etc/nixos/hardware-configuration.nix
    ```

    which will look similar to

    ```
    { config, pkgs, ... }:

    {
      imports = [ ];

      # Add line here as explained below

      # The rest of the file contains generated options.
    }
    ```

    Now add one of the following lines to the location mentioned in the example hardware config above.

    **Option 1**: UEFI

    ```
      boot.loader.systemd-boot.enable = true;
    ```

    **Option 2**: Legacy Boot (MBR)

    ```
      boot.loader.grub.device = "/dev/sda";
    ```

    Lastly, in rare circumstances the hardware configuration does not have a `fileSystems` option. In that case you need to add it with the following line:

    ```
      fileSystems."/".device = "/dev/disk/by-label/nixos";
    ```

6. Do the installation

    ```
    nixos-install
    ```

    Set root password

    ```
    setting root password...
    Enter new UNIX password:
    Retype new UNIX password:
    ```

7. If everything went well

    ```
    reboot
    ```

## 2. Nix installation
The following steps are meant to be run on the machine you deploy from, not the machine you deploy to.
You can also build Nix from source by following the instructions at https://nixos.org/nix/manual/#ch-installing-source.

1. Install dependencies (Debian 10 Buster)

    ```
    sudo apt-get install curl git gnupg2 dirmngr
    ```

2. Install the latest Nix in "multi-user mode" with GPG verification according to https://nixos.org/download/

    ```
    curl -o install-nix-2.3.10 https://releases.nixos.org/nix/nix-2.3.10/install
    curl -o install-nix-2.3.10.asc https://releases.nixos.org/nix/nix-2.3.10/install.asc
    gpg2 --recv-keys B541D55301270E0BCF15CA5D8170B4726D7198DE
    gpg2 --verify ./install-nix-2.3.10.asc
    sh ./install-nix-2.3.10 --daemon
    ```

    Then follow the instructions. Open a new terminal window when you're done.

    If you get an error similar to

    ```
    error: cloning builder process: Operation not permitted
    error: unable to start build process
    /tmp/nix-binary-tarball-unpack.hqawN4uSPr/unpack/nix-2.2.1-x86_64-linux/install: unable to install Nix into your default profile
    ```

    you're likely not installing as multi-user because you forgot to pass the `--daemon` flag to the install script.

3. Optional: Disallow substitutes

    You can put `substitute = false` to your `nix.conf` usually found in `/etc/nix/` to build the packages from source.
    This eliminates an attack vector where Nix's build server or binary cache is compromised.

<a id="3-setup-deployment-directory"></a>

## 3. Get and verify bitcoinix

1. Clone this project

    ```
    git clone https://github.com/bitcoinix/bitcoinix
    cd bitcoinix
    ```

2. Verify the release signing keys

    A bitcoinix release is a signed git tag. The list of keys that may sign releases lives in
    the repository you just cloned, so it cannot vouch for itself. Print the fingerprints
    of the listed keys:

    ```
    grep -v '^#' helper/release-keys/ssh-allowed-signers | cut -d' ' -f3- | ssh-keygen -lf -
    ```

    The release tag key, `SHA256:2o/0Op+64zKgF4oMaS0LGOiGPNDsibaqX6g8qMf5Hz0`, is also
    published outside this repository at <https://seberm.com/ssh.html>. Verify that statement
    as described on that page and check that the same fingerprint is listed above. Do not
    continue if it is not.

3. Verify and check out the latest release

    ```
    git config gpg.ssh.allowedSignersFile helper/release-keys/ssh-allowed-signers
    git config gpg.ssh.revocationFile helper/release-keys/ssh-revoked-keys
    git tag -l 'v*' --sort=-v:refname | head -1    # the latest release, e.g. v0.1.0
    git tag -v v<version>
    git checkout v<version>
    cd ..
    ```

    `git tag -v` must report `Good "git" signature` with the release tag key fingerprint
    from the previous step. Checking out the tag makes sure that the files used below, including
    `fetch-release.sh` and its key files, are the ones that were signed.

## 4. Deploy with a flake

Your node configuration is a Nix flake that has bitcoinix as an input. You deploy it from your
computer over SSH with `nixos-rebuild` or [Colmena](https://colmena.cli.rs/). CI builds both
examples on every change to bitcoinix.

1. Copy an example to a new directory next to the bitcoinix clone

    For `nixos-rebuild`, use [`examples/flakes`](https://github.com/bitcoinix/bitcoinix/blob/master/examples/flakes/flake.nix). For Colmena,
    use [`examples/colmena`](https://github.com/bitcoinix/bitcoinix/tree/master/examples/colmena), a larger node. Both use the secure-node
    preset.

    ```
    cp -r bitcoinix/examples/flakes node-config    # or bitcoinix/examples/colmena
    cd node-config
    git init
    ```

    Flakes only see files that git tracks, so `git add` every file you create.

2. Pin the release that you verified in step 3

    In `flake.nix`, set the `bitcoinix` input to the release tag:

    ```
    bitcoinix.url = "github:bitcoinix/bitcoinix/v<version>";
    ```

    Then lock the inputs and check that the locked commit is the one you verified:

    ```
    nix flake lock
    nix flake metadata --json | nix run nixpkgs#jq -- -r .locks.nodes.bitcoinix.locked.rev
    git -C ../bitcoinix rev-parse 'v<version>^{commit}'
    ```

    Both commands must print the same commit. Commit `flake.lock`, and repeat this step for
    every update.

3. Adapt the configuration

    Copy `hardware-configuration.nix` from your node and import it in place of the example's
    placeholders (in the Colmena example, replace `configs/fullnode/hardware-configuration.nix`):

    ```
    scp root@<node>:/etc/nixos/hardware-configuration.nix .
    ```

    Edit all lines marked `FIXME`. Above all, add your SSH public key to
    `users.users.root.openssh.authorizedKeys.keys`: the deployment logs in as root, and without
    the key you lose remote access to the node.

4. Deploy

    With `nixos-rebuild`:

    ```
    nix run nixpkgs#nixos-rebuild -- switch --flake .#fullnode --target-host root@<node>
    ```

    This builds the system on your computer and copies it to the node. To build on the node
    instead, for example when you deploy from macOS, add `--build-host root@<node>`.

    With Colmena, set `deployment.targetHost` in `flake.nix`, then:

    ```
    nix develop
    colmena apply --on fullnode
    ```

    `switch` (the Colmena default) activates the new system on the running node, which can
    cause problems. For updates, above all of bitcoinix, prefer `boot` and a reboot: replace
    `switch` with `boot` in the `nixos-rebuild` command, or run
    `colmena apply --on fullnode boot`, then `ssh root@<node> reboot`.

5. With the secure-node preset, you can now log in as the unprivileged `operator` user

    ```
    ssh operator@<node>
    ```

    bitcoinix authorizes the SSH keys of `root` for `operator`. Use `operator` for normal
    system management, and log in as `root` as rarely as possible.

## 5. Alternative: deploy with krops (legacy)

> [!NOTE]
> krops is the deployment tool of nix-bitcoin, the predecessor project. Support for it may be
> removed in a future release. Prefer a [flake-based deployment](#4-deploy-with-a-flake).

### Set up the deployment directory

These steps continue from step 3 above.

1. Create a new directory for your bitcoinix node config and copy initial files from bitcoinix

    ```
    mkdir nix-bitcoin-node
    cd nix-bitcoin-node
    cp -r ../bitcoinix/examples/{configuration.nix,shell.nix,krops,.gitignore} .
    ```

2. Obtain the hash of the latest bitcoinix release

    ```
    ../bitcoinix/helper/fetch-release.sh > nix-bitcoin-release.nix
    ```

    `fetch-release` picks the highest signed release tag, verifies it against
    `helper/release-keys/ssh-allowed-signers` and `helper/release-keys/ssh-revoked-keys`, and
    refuses to emit a hash for an unsigned tag, or for a tag signed by an unknown or revoked
    key. Pass `releaseVersion=<version>` to pin a specific release. Set `checkDownload=1` to
    additionally download the release archive into a throwaway Nix store and check that it is
    exactly the signed tree.

#### Optional: Specify the system of your node
This enables evaluating your node config on a machine that has a different system platform
than your node.\
Examples: Deploying from macOS or deploying from an x86 desktop PC to a Raspberry Pi.

```bash
# Run this when your node has a 64-bit x86 CPU (e.g., an Intel or AMD CPU)
echo "x86_64-linux" > krops/system

# Run this when your node has a 64-bit ARM CPU (e.g., Raspberry Pi 4 B, Pine64)
echo "aarch64-linux" > krops/system
```
Other available systems:
- `i686-linux` (`x86`)
- `armv7l-linux` (`ARMv7`)\
  This platform is untested and has no binary caches.
  [See here](https://nixos.wiki/wiki/NixOS_on_ARM) for details.

### Deploy with krops

1. Edit your SSH config

    ```
    nano ~/.ssh/config
    ```

    and add the node with an entry similar to the following (make sure to fix `Hostname` and `IdentityFile`):

    ```
    Host bitcoin-node
        # FIXME
        Hostname NODE_IP_ADDRESS_OR_HOST_NAME_HERE
        User root
        PubkeyAuthentication yes
        # FIXME
        IdentityFile ~/.ssh/id_...
        AddKeysToAgent yes
    ```

2. Make sure you are in the deployment directory and edit `krops/deploy.nix`

    ```
    nano krops/deploy.nix
    ```

    Locate the `FIXME` and set the target to the name of the SSH config entry created earlier, i.e. `bitcoin-node`.

    Note that any file imported by your `configuration.nix` must be copied to the target machine by krops.
    For example, if there is an import of `networking.nix` you must add it to `extraSources` in `krops/deploy.nix` like this:
    ```
    extraSources = {
        "hardware-configuration.nix".file = toString ../hardware-configuration.nix;
        "networking.nix".file = toString ../networking.nix;
    };
    ```

3. Optional: Disallow substitutes

    If you prefer to build the system from source instead of copying binaries from the Nix cache, add the following line to `configuration.nix`:
    ```
    nix.extraOptions = "substitute = false";
    ```

    If the build process fails for some reason when deploying with `krops-deploy` (see later step), it may be difficult to find the cause due to the missing output.
    To see the build output, SSH into the target machine and run
    ```
    nixos-rebuild -I /var/src switch
    ```

4. Copy `hardware-configuration.nix` from your node to the deployment directory.

    ```
    scp root@bitcoin-node:/etc/nixos/hardware-configuration.nix .
    ```

5. Adjust configuration by opening the `configuration.nix` file and enable/disable the modules you want by editing this file.

    ```
    nano configuration.nix
    ```

    Pay attention to lines that are preceded by `FIXME` comments. In particular:
    1. Make sure to set your SSH pubkey. Otherwise, you lose remote access because the config does not enable `permitRootLogin` (unless you add that manually).
    2. Uncomment the line `./hardware-configuration.nix` by removing `#`.

6. Enter the deployment environment

    ```
    nix-shell
    ```

7. Deploy with krops in nix-shell

    ```
    deploy
    ```

    This will now create a bitcoinix node on the target machine.

8. You can now access `bitcoin-node` via SSH

    ```
    ssh operator@bitcoin-node
    ```

    Note that you're able to log in as the unprivileged `operator` user because bitcoinix automatically authorizes the SSH key added to `root`.

For security reasons, all normal system management tasks can and should be performed with the `operator` user. Logging in as `root` should be done as rarely as possible.

See also:
- [Migrating existing services to bitcoinix](configuration.md#migrate-existing-services-to-bitcoinix)
- [Managing your deployment](configuration.md#managing-your-deployment)
- [Using services](services.md)
