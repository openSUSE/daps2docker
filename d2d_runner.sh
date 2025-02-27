#!/bin/bash

# daps2docker Docker/Podman Helper
# This script runs all the Docker/Podman related commands, having this in a separate
# scripts makes it easier to run with root privileges

OLDIFS="$IFS"

set -E
shopt -s extglob
[ -n "$DAPS2DOCKER_DEBUG" ] && {
  export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
  set -x
}

exec 3<&2 # preserve original stderr at fd 3


me=$(test -L $(realpath $0) && readlink $(realpath $0) || echo $(realpath $0))
mydir=$(dirname $me)

DATE=$(date "+%Y-%m-%dT%H:%M")

# The DAPS command
daps="daps --color=0"

error_exit() {
    # $1 - message string
    # $2 - error code (optional)
    # echo -e "(Exiting d2d_runner) $1" >&4
    log_critical "(Exiting d2d_runner) $1" >&2
    stop_container
    [[ $2 ]] && exit $2
    exit 1
}

output_rpmpackages_in_container() {
  local container_id=$1
  local queryformat='       - %{NAME}: %{VERSION}\n'

  log_debug "Package versions in container:"
  "$ENGINE" exec $container_id rpm -q --qf "$queryformat" \
      daps ditaa \
      libxslt-tools libxml2-tools xmlgraphics-fop xmlstarlet \
      docbook_5 docbook_4 geekodoc novdoc \
      docbook-xsl-stylesheets docbook5-xsl-stylesheets \
      suse-xsl-stylesheets suse-xsl-stylesheets-sbp hpe-xsl-stylesheets \
      libxml2-tools libxslt-tools jing \
      rsvg-convert inkscape \
      google-noto-sans-{jp,kr,sc,tc}-{regular,bold}-fonts \
      sil-charis-fonts gnu-free-fonts google-opensans-fonts dejavu-fonts google-poppins-fonts

    # We don't rely here on a specific name (like ruby2.5-rubygem-asciidoctor)
    # which can change in the future. That's why we use the "provides" name
    "$ENGINE" exec $container_id rpm -q \
       --qf "$queryformat" --whatprovides "rubygem(asciidoctor)"
}


# Source common functions and variables
if [ -e $mydir/daps2docker-common ]; then
  source $mydir/daps2docker-common
elif [ -e /usr/share/daps2docker/daps2docker-common ]; then
  source /usr/share/daps2docker/daps2docker-common
else
  error_exit "no 'daps2docker-common' found :-("
fi

# source $mydir/daps2docker-common || error_exit "ERROR: no daps2docker-common :-("

# declare -A valid_formats

app_help() {
  cat << EOF
  $0 / Build DAPS documentation in a container (inner script).

  Unlike daps2docker itself, this script assumes a few things:
    * [docker] the Docker service is running
    * [docker] the current user is allowed to run Docker
    * there is an empty output directory
  In exchange, you can run relatively arbitrary DAPS commands.

  Parameters (* mandatory):
    -e=CONTAINER_ENGINE   # *preferred engine to run the containers (docker|podman)
    -i=INPUT_PATH         # *path to input directory
    -o=OUTPUT_PATH        # *path to output directory (directory should be empty)
    -f=FORMAT1[,FORMAT2]  # formats to build; recognized formats:
                          # $(printf "%s " "${!valid_formats[@]}")
    -g=0/1                # debug on? default 0 (off)
    -v=0/1                # validate before building? default: 1 (on)
    -t=0/1                # run table validation? default: 1 (on)
    -d=PARAMETER_FILE     # file with extra DAPS parameters
    -x=PARAMETER_FILE     # file with extra XSLT processor parameters
    -c=DOCKER_IMAGE       # container image for building
    -u=0/1                # update container image? default: 1 (on)
    -s=USER_NAME          # chown output files to this user
    -b=0/1                # create bigfile. default: 0 (off)
    -j=0/1                # create filelist.json (depends on jq). default: 0 (off)
    -n=0/1                # show extra information? default: 1 (on)
    -m=0/1                # call daps metadata? default: 1 (on)
    DC-FILE xml/MAIN_FILE.xml adoc/MAIN_FILE.adoc
                          # DC/XML/AsciiDoc files to build from
EOF
}


format_filelists() {
  log_debug "Creating filelist $outdir/filelist"
  mkdir -p "$outdir"
  if [[ "$filelist" ]]; then
      echo "$filelist" | tr ' ' '\n' > "$outdir/filelist"
  fi
  [[ "$createjsonfilelist" -eq 1 ]] && echo '{'$(echo "$filelist_json" | sed -r 's/, *$//')'}' | jq > "$outdir/filelist.json"
  # [[ "$createjsonfilelist" -eq 1 ]] && jq -n --argjson files "[$filelist_json]" '{$files}' > "$outdir/filelist.json"
  log_debug "Created filelist"
}

json_line() {
  # $1 - document name
  # $2 - format
  # $3 - status ('succeeded'/'failed'),
  # $4 (optional) - file name
  local doc=$1
  local format=$2
  local status=$3
  # jq will deduplicate keys, therefore use a hash as the key
  local hash=$(echo "$1 $2" | md5sum | cut -b1-8)
  # local output_file="false"
  # [[ "$4" ]] && output_file="\"$4\""
  local output_file=${4:+\"$4\"}
  output_file=${output_file:-false}

  filelist_json+="\"$hash\": {\"document\": \"$doc\", \"format\": \"$format\", \"status\": \"$status\", \"file\": $output_file}, "
}


build_xsltparameters() {
    # $1 - file to work from
    local file="$1"
    local paramlist=
    while IFS= read -r line || [ -n "$line" ]; do
      # Skip lines that start with a hash (#)
        [[ "$line" =~ ^#.* ]] && continue

      # Check if the line is in the form key=value
      if [[ "$line" =~ ^[^=]+=[^=]+$ ]]; then
        paramlist+="--stringparam='$line' "
      else
        >&2 log_warn "Ignoring invalid line in XSLT parameter file: $line"
      fi
    done < "$file"
    echo "$paramlist"
}

build_dapsparameters() {
    # $1 - file to work from
    # $2 - current format
    paramlist=
    valid_params=$(echo -e "${valid_formats[$2]}" | tr ' ' '\n' | sed -n '/./ p' | sort -u)
    params=$(cat $1 | sed -n '/./ p' | sort -u)
    paramlist=$(comm -12 <(echo -e "$valid_params") <(echo -e "$params") | tr '\n' ' ')
    paramlist_dropped=$(comm -13 <(echo -e "$valid_params") <(echo -e "$params") | tr '\n' ' ')
    [[ $(echo "$paramlist_dropped" | sed -r 's/\s//g') ]] && >&2 log_warn "The following DAPS parameters are not supported either by DAPS or by daps2docker and have been dropped: $paramlist_dropped"
    echo "$paramlist"
}

clean_temp() {
    # Some things need to be deleted within Docker/Podman, because the user in the
    # container writes as root, but we may not have root permissions.
    if [[ "$container_id" ]]; then
        log_debug "Cleaning up in container ${container_id:0:10}"
        # TODO: Combine these two commands?
        exec_container rm -rf $containersourcetempdir/build
        exec_container rm -rf $containersourcetempdir/images/generated
    fi
    rm -rf $localtempdir 2>/dev/null
}

start_container() {
  local name="$1"
  local from="$2"
  local to="$3"
  local USER=$(get_user_group_id)

  log_debug "Starting container $name with bind mount $from -> $to and user $USER" >&4

  "$ENGINE" run \
    --user ${USER} \
    --detach \
    --mount type=bind,source="$localtempdir",target="$containertempdir" \
    "$containername" \
    tail -f /dev/null
}

stop_container() {
    if [[ "$container_id" ]]; then
        # stop the Daps container
        "$ENGINE" stop $container_id > /dev/null 2>&1

        # we won't ever use the same container again, so remove the container's files
        "$ENGINE" rm $container_id > /dev/null 2>&1
    fi
}

exec_container() {
  # $@ - command to execute
  local USER=$(get_user_group_id)
  # log_debug "Executing $@"
  "$ENGINE" exec --tty --user "$USER" ${container_id} "$@"
}

cp_container() {
  # $1 - source
  # $2 - target
  local source=$1
  local target=$2
  log_debug "Copying ${source@Q} to ${target@Q} in container ${container_id:0:10}"
  "$ENGINE" cp "${source}" "${container_id}:${target}"
}

cp_from_container() {
  # $1 - source
  # $2 - target
  local source=$1
  local target=$2
  log_debug "Copying ${source@Q} to ${target@Q} in container ${container_id:0:10}"
  "$ENGINE" cp "${container_id}:${source}" "${target}"
}


load_config_file() {
    # $1 the config file to be loaded
    #
    local config=$1
    if [[ -e $config ]]; then
        source "$config"
        index=$((index + 1))
        configfilelist[$index]=$config
    fi
}

## Error handling
check_for_unknown() {
  local args=$1
  [[ $args ]] && error_exit "Your command line contained the following unknown option(s):\n${args@Q}"
}

check_directory() {
  local dir="$1"
  [[ ! $dir ]] && error_exit "No input directory set."
  [[ -f $dir ]] && error_exit "Input directory \"$dir\" already exists but is a regular file."
  [[ ! -d $dir ]] && error_exit "Input directory \"$dir\" does not exist."
  [[ $(echo "$dir" | sed -r 's=^(/[-_.@a-zA-Z0-9]+)+/?$==') ]] && error_exit "Input directory \"$dir\" is a nonconformist path."
}

check_output_directory() {
  local dir="$1"
  [[ ! $dir ]] && error_exit "No output directory set."
  [[ -f $dir ]] && error_exit "Output directory \"$dir\" already exists but is a regular file."
  [[ $(echo "$dir" | sed -r 's=^(/[-_.@a-zA-Z0-9]+)+/?$==') ]] && error_exit "Output directory \"$dir\" is a nonconformist path."
}

check_parameterfiles_and_formats() {
  local fmts="$1"
  local dapsparamfile="$2"
  local xsltparamfile="$3"
  if ( [[ $dapsparamfile ]] || [[ $xsltparamfile ]] ) && [[ "$fmts" == *","* ]]; then
      error_exit "When using parameter files, only one format can be built. Decide!"
  fi
}

check_formats() {
  local fmts="$1"

  # Replaces all characters that are not ",", "-" or lowercase letters
  # Replaces all commas with spaces
  fmts=${fmts//[^-,a-z]/}
  fmts=${fmts//,/ }

  for f in $fmts; do
    if [[ ! " ${!valid_formats[@]} " =~ " $f " ]]; then
      error_exit "Requested format $f is not supported.\nSupported formats: $format_string"
    fi
  done
  echo $fmts
}

check_image_name() {
  local image="$1"
  # Not really sure it makes a lot of sense to validate this ultimately, there are
  # at least the following variations:
  #   Digest: d9483ffe78b4
  #   Name only: alpine
  #   Name and tag: alpine:latest
  #   Registry, name, tag: docker.io/alpine:latest
  #   Names on the registry can have additional path components: docker.io/susedoc/ci:latest
  if ! [[ "$image" =~ ^([-_.a-zA-Z0-9]+(/[-_.a-zA-Z0-9]+)*(:[-_.a-zA-Z0-9]+)?|[0-9a-f]+) ]]; then
    error_exit "Container name \"$image\" seems invalid."
  fi
}

check_autoupdate() {
  local value="$1"
  if [[ ! $(is_bool "$value") ]]; then
    error_exit "Automatic container update parameter ($value) is not set to 0 or 1."
  fi
}

check_debug() {
  local value="$1"
  if [[ ! $(is_bool "$value") ]]; then
    error_exit "Debug parameter ($value) is not set to 0 or 1."
  fi
}

check_autovalidate() {
  local value="$1"
  if [[ ! $(is_bool "$value") ]]; then
    error_exit "Automatic validation parameter ($value) is not set to 0 or 1."
  fi
}

check_validate_tables() {
  local value="$1"
  if [[ ! $(is_bool "$value") ]]; then
    error_exit "Table validation parameter ($value) is not set to 0 or 1."
  fi
}

check_createbigfile() {
  local value="$1"
  if [[ ! $(is_bool "$value") ]]; then
    error_exit "Bigfile creation parameter ($value) is not set to 0 or 1."
  fi
}

check_info() {
  local value="$1"
  if [[ ! $(is_bool "$value") ]]; then
    error_exit "Extra information parameter ($value) is not set to 0 or 1."
  fi
}

check_createjsonfilelist() {
  local value="$1"
  if [[ ! $(is_bool "$value") ]]; then
    error_exit "filelist.json creation parameter ($value) is not 0 or 1."
  fi
}

check_if_parameter_files_exists() {
  local dapsparamfile="$1"
  local xsltparamfile="$2"
  if [[ $dapsparamfile ]] && [[ ! -f $dapsparamfile ]]; then
    error_exit "DAPS parameter file ${dapsparamfile@Q} does not exist."
  fi
  if [[ $xsltparamfile ]] && [[ ! -f $xsltparamfile ]]; then
    error_exit "XSLT parameter file ${xsltparamfile@Q} does not exist."
  fi
}


# We use a cascade of config files. Later sourced files have a higher
# priority. Content of files with a higher priority overwrites content
# from files with lower priority.
# If a file cannot be found, it's not an error and silently ignored.

# We first need to load the array; we need to handle it differently from
# the rest
# load_config_file $SYSTEM_CONFIGDIR/default
# load_config_file $mydir/default

load_config_file $SYSTEM_CONFIGDIR/$DEFAULT_CONFIGNAME
# Make fallback to Git repo, if we are using the script from a local checkout
is_git_dir $mydir && load_config_file $mydir/$DEFAULT_CONFIGNAME
#
load_config_file $USER_CONFIGDIR/$DEFAULT_CONFIGNAME
load_config_file .git/$GIT_DEFAULT_CONFIGNAME

ENGINE=${CONTAINER_ENGINE:-docker}
IMAGENAME=${CONTAINER_NAME:-$imagename}
# Fallback to the old variable name
if [[ ! $IMAGENAME ]]; then
    IMAGENAME=${CONTAINER_NAME:-$containername}
fi

user=$(get_user_id)
user_change=0

dir=

outdir=

# $formats, via 'defaults' file

# $containername, via 'defaults' file
autoupdate=1

xsltparameterfile=
dapsparameterfile=

autovalidate=1
validatetables=1

createbigfile=0

info=1

debug=0

createjsonfilelist=0

dcfiles=

unknown=

metadata=1


for i in "$@"
  do
    case $i in
      -h|--help)
        app_help
        exit 0
      ;;
      -e=*|--container-engine=*)
        ENGINE="${i#*=}"
      ;;
      -s=*|--change-user=*)
        user_change=1
        user="${i#*=}"
      ;;
      -i=*|--in=*)
        dir="${i#*=}"
      ;;
      -o=*|--out=*)
        outdir="${i#*=}"
      ;;
      -f=*|--formats=*)
        formats="${i#*=}"
      ;;
      -c=*|--container=*)
        containername="${i#*=}"
      ;;
      -u=*|--container-update=*)
        autoupdate="${i#*=}"
      ;;
      -x=*|--xslt-param-file=*)
        xsltparameterfile="${i#*=}"
      ;;
      -d=*|--daps-param-file=*)
        dapsparameterfile="${i#*=}"
        ;;
      -g=*|--debug=*)
        debug="${i#*=}"
      ;;
      -v=*|--auto-validate=*)
        autovalidate="${i#*=}"
      ;;
      -t=*|--validate-tables=*)
        validatetables="${i#*=}"
      ;;
      -b=*|--create-bigfile=*)
        createbigfile="${i#*=}"
      ;;
      -j=*|--json-filelist=*)
        createjsonfilelist="${i#*=}"
      ;;
      -n=*|--info=*)
        info="${i#*=}"
      ;;
      -m=*|--metadata=*)
        metadata="${i#*=}"
        ;;
      DC-*|xml/*.xml|adoc/*.adoc)
        dcfiles+="${i#*=} "
      ;;
      *)
        unknown+="  $i\n"
      ;;
    esac
done

log_info "Config parameters"
log_info "   config files: ${configfilelist[@]}"
log_info "          image: $containername"
log_info "  valid formats:"
for item in "${!valid_formats[@]}" ; do
    log_info "    $item = \"${valid_formats[$item]}\""
done
log_info "---"

# Command line error handling
check_for_unknown "$unknown"
check_directory "$dir"
check_output_directory "$outdir"
check_parameterfiles_and_formats "$formats" "$dapsparameterfile" "$xsltparameterfile"
formats=$(check_formats "$formats")
check_image_name "$containername"
check_autoupdate "$autoupdate"
check_if_parameter_files_exists "$dapsparameterfile" "$xsltparameterfile"
check_debug "$debug"
check_autovalidate "$autovalidate"
check_validate_tables "$validatetables"
check_createbigfile "$createbigfile"
check_info "$info"
check_createjsonfilelist "$createjsonfilelist"


if [[ ! $dcfiles ]]; then
    cd $dir
    dcfiles=$(ls DC-*)
    cd - >/dev/null
fi
for dcfile in $dcfiles
  do
    [[ ! -f $dir/$dcfile ]] && error_exit "DC file \"$dcfile\" does not exist."
    [[ $(echo "$dcfile" | sed -r 's/^(DC-[-_.a-zA-Z0-9]+|(xml|adoc)\/[-_.a-zA-Z0-9]+\.\2)//') ]] && error_exit "$dcfile does not appear to be a valid input file."
done

localtempdir=$(mktemp -d -p /tmp d2drunner-XXXXXXXX)
localsourcetempdir="$localtempdir/source"
mkdir "$localsourcetempdir"

containertempdir=/daps_temp-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c10)
containersourcetempdir="$containertempdir/source"

[[ $autoupdate -eq 1 ]] && "$ENGINE" pull $containername

# Enable debugging with -g=1
[[ 1 -eq $debug ]] && daps="$daps --debug"

# If the container does not exist, this command will still output "[]", hence
# the sed. NB: We need to do this after the pull, as the pull might just
# produce the necessary image.
if [[ ! $("$ENGINE" image inspect $containername 2>/dev/null | sed 's/\[\]//') ]]
  then
    clean_temp
    error_exit "Container image $containername does not exist."
fi


container_name="$DATE"
# Remove colons and dsh sign
# Remove the timezone information if needed (optional)
container_name="${container_name//:/}"
container_name="${container_name//-/}"
container_name="${container_name%.*}"
container_name="daps-runner-$container_name"

# Example usage in a Docker-friendly name
# spawn a Daps container
# TODO: Name the container with --name=$container_name ?
container_id=$( \
  "$ENGINE" run \
    --detach \
    --mount type=bind,source="$localtempdir",target="$containertempdir" \
    "$containername" \
    tail -f /dev/null \
  )

# check if spawn was successful
if [ ! $? -eq 0 ]
  then
    clean_temp
    error_exit "Error spawning container."
fi

# first get the name of the container, then get the ID of the Daps container
log_info "Container ID: ${container_id:0:12} name=${container_name@Q}"

# copy all directories plus DC-file from the sourcedir
# except the build/ dir (if present)

log_debug "Syncing content to host directory $localtempdir/"
rsync -aL --exclude=build/ $dir/ $localsourcetempdir/

if [[ $info -eq 1 ]]; then
    output_rpmpackages_in_container "$container_id"
fi

# check whether we can/have to disable table validation (DAPS 3.3.0 is the first
# version that shipped with it, DAPS 3.3.1 first shipped the parameter to
# disable table validation everywhere; DAPS 3.3.0 is thus somewhat incompatible)
table_valid_param=''
daps_version_table_min=3.3.1
daps_version=$(exec_container rpm -q --qf '%{VERSION}' daps)
[[ "$validatetables" -eq 0 && \
  $(echo -e "$daps_version_table_min\n$daps_version" | sort --version-sort | head -1) = "$daps_version_table_min" ]] && \
  # TODO: We need to add it to the configuration file
  # table_valid_param='--extended-validation=all'
  table_valid_param=''

# build output formats
filelist=''
filelist_json=''
for dc_file in $dcfiles
  do
    dm="-d"
    [[ ! $(echo "$dc_file" | sed -r 's/^(xml|adoc)\///') ]] && dm="-m"
    log_info "Building $dc_file"

    # This should be in there anyway, we just write it again just in case the
    # container author has forgotten it.
    echo 'DOCBOOK5_RNG_URI="urn:x-suse:rng:v2:geekodoc-flat"' > $localtempdir/d2d-dapsrc-geekodoc
    echo 'DOCBOOK5_RNG_URI="file:///usr/share/xml/docbook/schema/rng/5.2/docbookxi.rng"' > $localtempdir/d2d-dapsrc-db52

    validation=
    validation_code=0
    if [[ "$autovalidate" -ne 0 ]]; then
      cp_container $localtempdir/d2d-dapsrc-geekodoc  /root/.config/daps/dapsrc

      log_debug "Validate inside container $ENGINE exec ${container_id:0:10} $daps $dm $containersourcetempdir/$dc_file validate $table_valid_param"
      validation=$(exec_container "$daps" "$dm" "$containersourcetempdir/$dc_file" validate "$table_valid_param" 2>&1)
      validation_code=$?
      log_debug "Validation for $dc_file result was $validation_code"

      validation_attempts=1
      if [[ "$validation_code" -gt 0 ]]; then
            # Try again but with the DocBook upstream
            log_debug "Use DocBook 5.x for validation with daps"
            cp_container $localtempdir/d2d-dapsrc-db52 /root/.config/daps/dapsrc
            validation=$(exec_container $daps $dm $containersourcetempdir/$dc_file validate "$table_valid_param" 2>&1)
            validation_code=$?
            validation_attempts=2
      fi
    else
        # Make sure we are not using GeekoDoc in this case, to provoke lowest
        # number of build failures
        log_debug "Use DocBook 5.x configuration for validation "
        cp_container $localtempdir/d2d-dapsrc-db52 /root/.config/daps/dapsrc
    fi

    log_debug "Checking validation result..."
    if [[ "$validation_code" -gt 0 ]]; then
        echo -e "$validation"
        clean_temp
        json_line "$dc_file" "validate" "failed"
        format_filelists
        error_exit "$dc_file has validation issues and cannot be built."
    else
        log_debug "Validation for $dc_file succeeded"
        json_line "$dc_file" "validate" "succeeded"
        [[ $validation_attempts -gt 1 ]] && log_warn "$dc_file has validation issues when trying to validate with GeekoDoc. It validates with DocBook though. Results might not look ideal."

        for format in $formats; do
            format_subcommand="$format"
            [[ $format == 'single-html' ]] && format_subcommand='html --single'
            dapsparameters=
            xsltparameters=
            [[ $dapsparameterfile ]] && dapsparameters+=$(build_dapsparameters $dapsparameterfile $format_subcommand)
            [[ $xsltparameterfile ]] && xsltparameters+=$(build_xsltparameters $xsltparameterfile)
            log_debug "$daps $dm $containersourcetempdir/$dc_file $format_subcommand $dapsparameters $xsltparameters"
            output=$(exec_container $daps $dm $containersourcetempdir/$dc_file $format_subcommand "$table_valid_param" $dapsparameters $xsltparameters)
            build_code=$?

            log_debug "Exit code from container: ${build_code@Q}"
            log_debug ""
            output=$(echo "$output" | tail -n1 | tr -d '\r')
            log_debug "Output from container: ${output@Q}"

            if [[ "$build_code" -gt 0 ]]; then
                clean_temp
                json_line "$dc_file" "$format" "failed"
                format_filelists
                error_exit "For $dc_file, the output format $format cannot be built. Exact message:\n\n${output}\n"
            else
                output_path=$(echo "$output" | sed -r -e "s#^$containersourcetempdir/build#$outdir#")
                # output_path="${output/#$containersourcetempdir\/build/$outdir}"
                filelist+="$output_path "
                json_line "$dc_file" "$format" "succeeded" "$output_path"

                # FIXME: The --create-bigfile option is used by Docserv2
                # which also uses the DAPS/XSLT parameter file options which
                # are incompatible with building multiple formats at once
                # currently. This handling is slightly ugly, it might be
                # better to allow format-specific parameter files.

                # Let's just assume that we can always build a bigfile if we can
                # build regular output.
                if [[ $createbigfile -eq 1 ]]; then
                    output=$(exec_container $daps $dm $containersourcetempdir/$dc_file bigfile "$table_valid_param" | tail -n1)
                    output_path=$(echo "$output" | sed -r -e "s#^$containersourcetempdir/build#$outdir#" | tr -d '\r')

                    # output_path="${output/#$containersourcetempdir\/build/$outdir}"
                    filelist+="${output_path} "
                    log_debug "DC $dc_file bigfile succeeded ${output_path}"
                    json_line "$dc_file" "bigfile" "succeeded" "${output_path}"
                fi
            fi
            # Run daps metadata only once
            # Remove any "/" from the DC file
            metafile="/$containertempdir/${dc_file%/}${META_PREFIX}"
            if [[ $metadata -eq 1 && ! -f "$metafile" ]]; then
                log_debug "Retrieving metadata for $dc_file => ${metafile}"
                log_debug "Executing in container: $daps $dm $containersourcetempdir/$dc_file metadata --output ${metafile}"
                exec_container $daps $dm $containersourcetempdir/$dc_file metadata --output ${metafile}
                # filelist+="${metafile} "
                cp_from_container $metafile $outdir
                log_debug "Succeeded to generated metadata for $dc_file -> ${metafile}"
            else
                log_warn "Skipping metadata for ${dc_file}/${format}"
            fi
        done
    fi
done

# copy the finished product to final directory
mkdir -p $outdir
cp -r $localsourcetempdir/build/. $outdir
format_filelists

# clean up
clean_temp
stop_container

log_info "All done. Output is in $outdir"

exit 0
