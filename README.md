# Daps2Docker

Create HTML and PDF output of documents in a DAPS-compatible DocBook or
ASCIIDoc documentation repository. This script uses Docker (default) or Podman
to save you the hassles of setting up a documentation toolchain.

## Installation

1. Install the package for your distribution.

For `Docker`:

*  OpenSUSE/SLES: `sudo zypper install docker`
*  Fedora/RHEL: `sudo dnf install docker`
*  Ubuntu/Debian: `sudo apt install docker.io`


For `Podman`:

* See [Official documentation](https://github.com/containers/libpod/blob/master/install.md)


2. Clone this repository: `git clone https://github.com/openSUSE/daps2docker`

## Usage

By default, `daps2docker` uses `docker` as a container engine.
In order to use `podman`, it is required to export the environment
variable `CONTAINER_ENGINE=podman`:

```console
$ export CONTAINER_ENGINE=podman
```

### First-Run Prerequisites

On the first run, Docker/Podman needs to download a container
with an installation of DAPS on openSUSE Leap.

This means, you need:

*  Make sure you have at least 1.5 GB of space on your root partition left
*  Make sure you have internet access

### Running

1. Clone a DAPS-compatible documentation repository.
2. The `DC-` files in the documentation repository correspond to documents.
   Check which `DC-` files you want to build.
3. Run the script from the cloned script repository. You can choose between two
   modes:
   *  To build all DC files: `./daps2docker.sh /PATH/TO/DOC-DIR`
   *  To build a single DC file: `./daps2docker.sh /PATH/TO/DC-FILE`
   By default, the script will create PDF and HTML output, but there are
   more formats available: See the output of `./daps2docker.sh --help`.
4. For `docker`, you may have to enter the root password to allow starting
   the Docker service. This also apply to start/stop containers independently
   of the container engine.

When it is done, the script will tell you where it copied the output documents.
Now you just need to take a look!

## References

* For the container image itself, see
  [Docker Hub](https://hub.docker.com/r/susedoc/ci).
* For the container definition, see
  [the doc-ci repository](https://github.com/openSUSE/doc-ci/tree/develop/build-docker-ci).
