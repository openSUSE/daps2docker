# Daps2Docker

Create HTML and PDF output of documents in a DAPS-compatible DocBook or
AsciiDoc documentation repository. This script uses Docker (default) or Podman
to save you the hassles of setting up a documentation toolchain.

## Installation

1. Install the package for your distribution.

   For Docker engine:
   *  OpenSUSE/SLES: `sudo zypper install docker`
   *  Fedora/RHEL: `sudo dnf install docker`
   *  Ubuntu/Debian: `sudo apt install docker.io`

   For Podman engine:
   *  The minimum required version is `1.1.0`.
      On openSUSE Leap 15.1, use the `podman` version from the OBS project
      `devel:kubic`. On openSUSE Tumbleweed, use the default version of `podman`.
      For more installation advice, see the [official documentation](https://github.com/containers/libpod/blob/master/install.md).


2. Choose whether to install from the repository or as a package:
   * For openSUSE/SLE, there is a package available at: https://build.opensuse.org/package/show/Documentation:Tools/daps2docker
   * Alternatively, clone this repository: `git clone https://github.com/openSUSE/daps2docker`


## Configuration

Daps2docker allows to define variables in different configuration files.
Similar to Git, you can use the following configuration files:

* system-wide: `/etc/daps2docker/config`
* user: `~/.config/daps2docker/config`
* specific to a repository: `.daps2docker.conf`

The priority raises from top to bottom. The Git repo configuration has the highest priority and overwrites any settings from config files of lower priorities.

In most cases, it's recommended to copy the system-wide configuration into
your home and adapt it to your needs:

```bash
mkdir -p ~/.config/daps2docker
cp /etc/daps2docker/config ~/.config/daps2docker/config
```

### First-Run Prerequisites

On the first run, Docker or Podman needs to download a container
with an installation of DAPS on openSUSE Leap.

This means, you need:

*  Make sure you have at least 1.5 GB of space on your root partition left
*  Make sure you have internet access


### Creating Output Documents

1. Clone a DAPS-compatible documentation repository.
2. The `DC-` files in the documentation repository correspond to documents.
   Check which `DC-` files you want to build.
3. *(optional)* By default, `daps2docker` uses `docker` as its container engine.
   To use `podman`, export the environment variable `CONTAINER_ENGINE=podman`:
   ```console
   $ export CONTAINER_ENGINE=podman
   ```
4. Run the script from the cloned script repository. You can choose between two
   modes:
   *  To build all DC files: `./daps2docker.sh /PATH/TO/DOC-DIR`
   *  To build a single DC file: `./daps2docker.sh /PATH/TO/DC-FILE`
   By default, the script will create PDF and HTML output, but there are
   more formats available: See the output of `./daps2docker.sh --help`.
5. You may have to enter the `root` password.
   *  If you are using the Docker engine, this allows starting the Docker
      service. It also allows starting/stopping containers when your user
      account is not part of the `docker` group.
   *  If you are using Podman, this allows starting/stopping containers.
      (Rootless Podman is currently not supported.)

When it is done, the script will tell you where it copied the output documents.
Take a look!

## References

* For the container image itself, see
  [Docker Hub](https://hub.docker.com/r/susedoc/ci).
* For the container definition, see
  [the doc-ci repository](https://github.com/openSUSE/doc-ci/tree/develop/build-docker-ci).
