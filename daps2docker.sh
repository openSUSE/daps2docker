#! /bin/bash

# daps2docker
# Author: Fabian Baumanis
#
# A script which takes a DAPS build directory, loads it into a DAPS container,
# builds it, and returns the directory with the built documentation.

VERSION=0.15

container_engine=docker
[[ "$CONTAINER_ENGINE" == 'podman' ]] && container_engine=$CONTAINER_ENGINE
[[ $CONTAINER_ENGINE != $container_engine && -n $CONTAINER_ENGINE ]] && \
  echo "[WARN] Using $container_engine instead of requested unsupported container engine \"$CONTAINER_ENGINE\"."
minimum_podman_version=1.1.0

me=$(test -L $(realpath $0) && readlink $(realpath $0) || echo $(realpath $0))
mydir=$(dirname $me)
# Our output directory:
outdir=""

# debug is off by default
debug=0

error_exit() {
    # $1 - message string
    # $2 - error code (optional)
    echo -e "[ERROR] $1"
    [[ $2 ]] && exit $2
    exit 1
}

# Source common functions and variables
if [ -e $mydir/daps2docker-common ]; then
  source $mydir/daps2docker-common
elif [ -e /usr/share/daps2docker/daps2docker-common ]; then
  source /usr/share/daps2docker/daps2docker-common
else
  error_exit "ERROR: no daps2docker-common found :-("
fi


# We use a cascade of config files. Later sourced files have a higher
# priority. Content of files with a higher priority overwrites content
# from files with lower priority.
# If a file cannot be found, it's not an error and silently ignored.
load_config_file $SYSTEM_CONFIGDIR/$DEFAULT_CONFIGNAME
# Make fallback to Git repo, if we are using the script from a local checkout
is_git_dir $mydir && load_config_file $mydir/$DEFAULT_CONFIGNAME
#
load_config_file $USER_CONFIGDIR/$DEFAULT_CONFIGNAME


app_help() {
  echo "daps2docker / Build DAPS documentation in a container."
  echo "Usage:"
  echo "  (1) $0 [DOC_DIR] [FORMAT]"
  echo "      # Build all DC files in DOC_DIR"
  echo "  (2) $0 [DC_FILE] [FORMAT]"
  echo "      # Build specific DC file as FORMAT"
  echo "  (3) $0 --outputdir=/tmp/daps2docker-1 [DC_FILE] [FORMAT]"
  echo "      # Build specific DC file(s) as FORMAT, but store output in a static directory"
  echo "If FORMAT is omitted, daps2docker will build: $formats."
  echo "Supported formats: ${!valid_formats[@]}."
  if [[ "$1" == "extended" ]]
    then
      echo ""
      echo "Extended options:"
      echo "  D2D_IMAGE=[CONTAINER_IMAGE_ID] $0 [...]"
      echo "      # Use the container image with the given ID instead of the default."
      echo "      # Note that the specified image must be available locally already."
      echo
      echo "  Found config files (in this order):"
      echo "  => ${configfilelist[@]}"
      echo
      echo "--debug"
      echo "  Enable debugging mode (very verbose)"
  else
      echo ""
      echo "More? Use $0 --help-extended"
  fi
  exit
}

#----------------
# Parse the command line arguments

ARGS=$(getopt -o h -l debug,help,help-extended,outputdir: -n "$ME" -- "$@")

eval set -- "$ARGS"
while true ; do
    case "$1" in
    --debug)
      debug=1
      shift
      ;;
    --help|-h)
      app_help
      ;;
    --help-extended)
      app_help extended
      ;;
    --outputdir)
      outdir="$2"
      shift 2
      ;;
    --) shift ; break ;;
    *) error_exit "Wrong parameter: $1" ;;
  esac
done

gitdir=$(get_toplevel_gitdir $1)
load_config_file $gitdir/$GIT_DEFAULT_CONFIGNAME
#
# After we've loaded the last config file, we have a list in our
# variable configfilelist

echo "[INFO] Using conf files: ${configfilelist[@]}"

if [ -z "$outdir" ]; then
  outdir=$(mktemp -d -p /tmp daps2docker-XXXXXXXX)
else
  mkdir -p "$outdir" 2>/dev/null
fi
echo "[INFO] Using output directory $outdir"


which $container_engine >/dev/null 2>/dev/null
if [ $? -gt 0 ]
  then
    error_exit "$container_engine is not installed. Install the '$container_engine' package of your distribution."
fi

if [[ $container_engine == 'podman' ]]
  then
    installed_podman_version=$(podman --version | awk '{print $3}')
    if [[ $minimum_podman_version != $(echo -e "$minimum_podman_version\n$installed_podman_version" | sort --version-sort | head -1) ]]
      then
        error_exit "Installed version of $container_engine is not supported. Make sure to install version $minimum_podman_version or higher."
    fi
fi


autoupdate=1
if [[ ! -z "$D2D_IMAGE" ]] && [[ ! $(echo "$D2D_IMAGE" | sed -r 's=^([-_.a-zA-Z0-9]+(/[-_.a-zA-Z0-9]+)*(:[-_.a-zA-Z0-9]+)?|[0-9a-f]+)==') ]]
  then
    autoupdate=0
    containername=$D2D_IMAGE
    echo "[INFO] Using custom container image ID $containername."
elif [[ ! -z "$D2D_IMAGE" ]]
  then
    error_exit "$D2D_IMAGE is not a plausible container image ID."
fi

# create absolute path and strip trailing '/' if any
# (otherwise the ls below will not work)
dir=$(readlink -f -- "$1" | sed 's_/$__')

if [ -d "$dir" ]
  then
    if [[ $(ls -- $dir/DC-*) ]]
      then
        dc_files=$(ls -- $dir | grep 'DC-*')
        echo -e "[INFO] Building DC file(s): "$(echo -e -n "$dc_files" | tr '\n' ' ')
      else
        error_exit "[ERROR] No DC files found in $dir."
    fi
  elif [ -f $dir ] && [[ $(basename -- $dir | grep '^DC-') ]]
  then
    dc_files=$(basename -- $dir)
    dir=$(dirname -- $dir)
    echo -e "[INFO] Building DC file: $dc_files"
  else
    message_addendum=''
    [[ "$1" == '-d' || "$1" == '-m' ]] && message_addendum=" $1 is not required for daps2docker."
    error_exit "Directory $dir does not exist.$message_addendum"
fi

shift
if [[ "$1" ]]
  then
    requested_format=$(echo "$1" | sed 's/[^-a-z0-9]//g')
    format_string=$(echo "${!valid_formats[@]}")
    if [[ $(echo " $format_string " | grep " $requested_format ") ]]
      then
        formats="$requested_format"
      else
        error_exit "Requested format $1 is not supported.\nSupported formats: $format_string"
    fi
fi
echo "[INFO] Building formats: $formats"
formats=$(echo "$formats" | sed 's/ /,/')

if [[ "$container_engine" == "docker" ]]; then
  systemctl is-active docker >/dev/null
  service_status=$?
  if [ $service_status -eq 3 ]
    then
      if [[ ! $EUID -eq 0 ]]
        then
          echo "[HINT] Docker service is not running. Give permission to start it."
          sudo systemctl start docker.service
        else
          systemctl start docker.service
      fi
    elif [ $service_status -gt 0 ]
      then
      error_exit "Issue with Docker service. Check 'systemctl status docker' yourself."
  fi
fi

# Find out if we need elevated privileges (very likely, as that is the default)
if [[ $(getent group docker | grep "\b$(whoami)\b" 2>/dev/null) && $container_engine == 'docker' ]] || [[ $EUID -eq 0 ]]
  then
    $mydir/d2d_runner.sh -e="$container_engine" -o="$outdir" -i="$dir" -f="$formats" -c="$containername" -u="$autoupdate" -g=$debug $dc_files
  else
    if [[ "$container_engine" == "docker" ]]; then
      echo -n "Your user account is not part of the group 'docker'."
    fi
    echo "$container_engine needs to be run as root."
    sudo $mydir/d2d_runner.sh -e="$container_engine" -s=$(whoami) -o="$outdir" -i="$dir" -f="$formats" -c="$containername" -u="$autoupdate" -g=$debug $dc_files
fi
if [[ -d "$outdir" ]] && [[ -f "$outdir/filelist" ]]
  then
    echo -e "Your output documents are:"
    cat "$outdir/filelist"
  else
    error_exit "Oh no. There are no documents for you."
fi
