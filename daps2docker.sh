#! /bin/sh

# daps2docker
# A script which takes a DAPS build directory, loads it into a DAPS docker
# container, builds it, and returns the directory with the built documentation.

outdir=$(mktemp -d -p /tmp daps2docker-XXXXXX)
me=$(test -L $(realpath $0) && readlink $(realpath $0) || echo $(realpath $0))
mydir=$(dirname $me)
formats="html pdf"
valid_formats="bigfile epub html online-docs pdf package-html package-pdf package-src single-html webhelp"

error_exit() {
    # $1 - message string
    # $2 - error code (optional)
    echo -e "$1"
    [[ $2 ]] && exit $2
    exit 1
}

app_help() {
  echo "daps2docker / Build DAPS documentation in a Docker container."
  echo "Usage:"
  echo "  (1) $0 [DOC_DIR] [FORMAT]"
  echo "      # Build all DC files in DOC_DIR"
  echo "  (2) $0 [DC_FILE] [FORMAT]"
  echo "      # Build specific DC file as FORMAT"
  echo "If FORMAT is omitted, daps2docker will build: $formats."
  echo "Recognized formats: $valid_formats."
  if [[ "$1" == "extended" ]]
    then
      echo ""
      echo "Extended options:"
      echo "  D2D_IMAGE=[DOCKER_IMAGE_ID] $0 [...]"
      echo "      # Use the Docker image with the given ID instead of the default."
      echo "      # Note that the specified image must be available locally already."
  else
      echo ""
      echo "More? Use $0 --help-extended"
  fi
}

which docker >/dev/null 2>/dev/null
if [ $? -gt 0 ]
  then
    error_exit "Docker is not installed. Install the 'docker' package of your distribution."
fi

if [ $# -eq 0 ] || [[ $1 == '--help' ]] || [[ $1 == '-h' ]]
  then
    app_help
    exit
elif [[ $1 == '--help-extended' ]]
  then
    app_help extended
    exit
fi

autoupdate=1
containername=susedoc/ci:openSUSE-42.3
if [[ ! -z "$D2D_IMAGE" ]] && [[ ! $(echo "$D2D_IMAGE" | sed -r 's/[0-9a-f]//g') ]]
  then
    autoupdate=0
    containername=$D2D_IMAGE
    echo "Using custom container image ID $containername."
elif [[ ! -z "$D2D_IMAGE" ]]
  then
    error_exit "$D2D_IMAGE is not a plausible container image ID."
fi

# create absolute path and strip trailing '/' if any
# (otherwise the ls below will not work)
dir=$(readlink -f "$1" | sed 's_/$__')

if [ -d "$dir" ]
  then
    if [[ $(ls $dir/DC-*) ]]
      then
        dc_files=$(ls $dir | grep 'DC-*')
        echo -e "Building DC file(s): "$(echo -e -n "$dc_files" | tr '\n' ' ')
      else
        error_exit "No DC files found in $dir."
    fi
  elif [ -f $dir ] && [[ $(basename $dir | grep '^DC-') ]]
  then
    dc_files=$(basename $dir)
    dir=$(dirname $dir)
    echo -e "Building DC file: $dc_files"
  else
    exit "Directory $dir does not exist."
fi

shift
if [[ "$1" ]]
  then
    requested_format=$(echo "$1" | sed 's/[^-a-z0-9]//g')
    if [[ $(echo "$valid_formats" | grep -P "\b$requested_format\b") ]]
      then
        formats="$requested_format"
      else
        error_exit "Requested format $1 is not supported.\nSupported formats: $valid_formats"
    fi
fi
echo "Building formats: $formats"
formats=$(echo "$formats" | sed 's/ /,/')

# Find out if we need elevated privileges (very likely, as that is the default)
if [[ $(getent group docker | grep "\b$(whoami)\b" 2>/dev/null) ]]
  then
    $mydir/docker_helper.sh '!!no-user-change' "$outdir" "$dir" "$formats" "$containername" "$autoupdate" $dc_files
  else
    echo "Your user account is not part of the group 'docker'. Docker needs to be run as root."
    sudo $mydir/docker_helper.sh $(whoami) "$outdir" "$dir" "$formats" "$containername" "$autoupdate" $dc_files
fi
if [[ -d "$outdir" ]] && [[ -f "$outdir/filelist" ]]
  then
    echo -e "Your output documents are:"
    cat "$outdir/filelist"
  else
    error_exit "Oh no. There are no documents for you."
fi
