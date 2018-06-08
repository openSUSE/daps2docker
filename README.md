# Daps2Docker

Create HTML and PDF output of documents in a DAPS-compatible DocBook or
ASCIIDoc documentation repository. This script uses Docker to save you the
hassles of setting up a documentation toolchain.

## Installation

1. Install the Docker package for your distribution. For example:
  * OpenSUSE/SLES: `sudo zypper install docker`
  * Fedora/RHEL: `sudo dnf install docker`
  * Ubuntu/Debian: `sudo apt install docker.io`
2. Clone this repository: `git clone https://github.com/openSUSE/daps2docker`

## Usage

### First-Run Prerequisites

On the first run, Docker needs to download a container with an installation
of DAPS on openSUSE Leap. This means, you need:

* Make sure you have at least 1.5 GB of space on your root partition left
* Make sure you have internet access

### Running

1. Clone a DAPS-compatible documentation repository.
2. The `DC-` files in the documentation repository correspond to documents.
  Check which `DC-` files you want to build.
3. Run the script from the cloned script repository. You can choose between two
  modes:
    * To build all DC files: `./daps2docker.sh /PATH/TO/DOC-DIR`
    * To build a single DC file: `./daps2docker.sh /PATH/TO/DC-FILE`
  By default, the script will create PDF and HTML output, but there are
  more formats available: See the output of `./daps2docker.sh --help`.
4. You may have to enter the root password to allow starting the Docker service
  or a Docker container.

When it is done, the script will tell you where it copied the output documents.
Now you just need to take a look!
