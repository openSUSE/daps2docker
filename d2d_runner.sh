#!/usr/bin/env bash

# daps2docker Docker/Podman Helper
# This script runs all the Docker/Podman related commands, having this in a separate
# scripts makes it easier to run with root privileges

me=$(test -L $(realpath $0) && readlink $(realpath $0) || echo $(realpath $0))
mydir=$(dirname $me)

# The DAPS command
daps="daps"

error_exit() {
    # $1 - message string
    # $2 - error code (optional)
    echo -e "(Exiting d2d_runner) $1"
    stop_container
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

# source $mydir/daps2docker-common || error_exit "ERROR: no daps2docker-common :-("

# declare -A valid_formats

app_help() {
  echo "$0 / Build DAPS documentation in a container (inner script)."
  echo "Unlike daps2docker itself, this script assumes a few things:"
  echo "  * [docker] the Docker service is running"
  echo "  * [docker] the current user is allowed to run Docker"
  echo "  * there is an empty output directory"
  echo "In exchange, you can run relatively arbitrary DAPS commands."
  echo ""
  echo "Parameters (* mandatory):"
  echo "  -e=CONTAINER_ENGINE   # *prefered engine to run the containers (docker|podman)"
  echo "  -i=INPUT_PATH         # *path to input directory"
  echo "  -o=OUTPUT_PATH        # *path to output directory (directory should be empty)"
  echo "  -f=FORMAT1[,FORMAT2]  # formats to build; recognized formats:"
  echo "${!valid_formats[@]}" | fold -w 54 -s | sed 's/^/                          /'
  echo "  -g=0/1                # debug on? default 0 (off)"
  echo "  -v=0/1                # validate before building? default: 1 (on)"
  echo "  -t=0/1                # run table validation? default: 1 (on)"
  echo "  -d=PARAMETER_FILE     # file with extra DAPS parameters"
  echo "  -x=PARAMETER_FILE     # file with extra XSLT processor parameters"
  echo "  -c=DOCKER_IMAGE       # container image for building"
  echo "  -u=0/1                # update container image? default: 1 (on)"
  echo "  -s=USER_NAME          # chown output files to this user"
  echo "  -b=0/1                # create bigfile. default: 0 (off)"
  echo "  -j=0/1                # create filelist.json (depends on jq). default: 0 (off)"
  echo "  -n=0/1                # show extra information? default: 1 (on)"
  echo "  DC-FILE xml/MAIN_FILE.xml adoc/MAIN_FILE.adoc"
  echo "                        # DC/XML/AsciiDoc files to build from"
}


format_filelists() {
  mkdir -p "$outdir"
  if [[ "$filelist" ]]
    then
      echo "$filelist" | tr ' ' '\n' > "$outdir/filelist"
  fi
  [[ "$createjsonfilelist" -eq 1 ]] && echo '{'$(echo "$filelist_json" | sed -r 's/, *$//')'}' | jq > "$outdir/filelist.json"
}

json_line() {
  # $1 - document name, $2 - format, $3 - status ('succeeded'/'failed'),
  # $4 (optional) - file name

  # jq will deduplicate keys, therefore use a hash as the key
  local hash=$(echo "$1 $2" | md5sum | cut -b1-8)
  local output_file="false"
  [[ "$4" ]] && output_file="\"$4\""
  filelist_json+="\"$hash\": {\"document\": \"$1\", \"format\": \"$2\", \"status\": \"$3\", \"file\": $output_file}, "
}

is_bool() {
    # $1 - value to check for boolness
    [[ "$1" == 0 || "$1" == 1 ]] && echo "isbool"
}

build_xsltparameters() {
    # $1 - file to work from
    paramlist=
    params=$(cat $1)
    paramlen=$(echo -e "$params" | wc -l)
    for l in $(seq 1 $paramlen)
      do
        line=$(echo -e "$params" | sed -n "$l p")
        [[ ! $(echo "$line" | sed -r 's/\s//g') ]] && continue
        paramlist+="--stringparam='$line' "
    done
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
    [[ $(echo "$paramlist_dropped" | sed -r 's/\s//g') ]] && >&2 echo "[WARN] The following DAPS parameters are not supported either by DAPS or by daps2docker and have been dropped: $paramlist_dropped"
    echo "$paramlist"
}

clean_temp() {
    # Some things need to be deleted within Docker/Podman, because the user in the
    # container writes as root, but we may not have root permissions.
    if [[ "$container_id" ]]
      then
        "$container_engine" exec $container_id rm -rf $containersourcetempdir/build
        "$container_engine" exec $container_id rm -rf $containersourcetempdir/images/generated
    fi
    rm -rf $localtempdir 2>/dev/null
}

stop_container() {
    if [[ "$container_id" ]]
      then
        # stop the Daps container
        "$container_engine" stop $container_id >/dev/null 2>/dev/null

        # we won't ever use the same container again, so remove the container's files
        "$container_engine" rm $container_id >/dev/null 2>/dev/null
    fi
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

is_git_dir() {
    # $1 the directory to check if it's a local Git repo
    git -C $1 rev-parse 2>/dev/null; return $?
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

container_engine=${CONTAINER_ENGINE:-docker}
containername=${CONTAINER_NAME:-$containername}

user=$(whoami)
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

for i in "$@"
  do
    case $i in
      -h|--help)
        app_help
        exit 0
      ;;
      -e=*|--container-engine=*)
        container_engine="${i#*=}"
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
      DC-*|xml/*.xml|adoc/*.adoc)
        dcfiles+="${i#*=} "
      ;;
      *)
        unknown+="  $i\n"
      ;;
    esac
done

echo "[INFO] Config parameters"
echo "   config files: ${configfilelist[@]}"
echo "      container: $containername"
echo "  valid formats:"
for item in "${!valid_formats[@]}" ; do
    echo "    $item = \"${valid_formats[$item]}\""
done
echo "---"

# Command line error handling

[[ $unknown ]] && error_exit "Your command line contained the following unknown option(s):\n$unknown"

[[ ! $dir ]] && error_exit "No input directory set."
[[ -f $dir ]] && error_exit "Input directory \"$dir\" already exists but is a regular file."
[[ ! -d $dir ]] && error_exit "Input directory \"$dir\" does not exist."
[[ $(echo "$dir" | sed -r 's=^(/[-_.@a-zA-Z0-9]+)+/?$==') ]] && error_exit "Input directory \"$dir\" is a nonconformist path."

[[ ! $outdir ]] && error_exit "No output directory set."
[[ -f $outdir ]] && error_exit "Output directory \"$outdir\" already exists but is a regular file."
[[ $(echo "$outdir" | sed -r 's=^(/[-_.@a-zA-Z0-9]+)+/?$==') ]] && error_exit "Output directory \"$dir\" is a nonconformist path."

(([[ $dapsparameterfile ]] || [[ $xsltparameterfile ]]) && [[ $(echo "$formats" | grep -o ',') ]]) && error_exit "When using parameter files, only one format can be built. Decide!"
formats=$(echo "$formats" | sed  -e 's/[^-,a-z]//g' -e 's/,/ /g')
for format in $formats
  do
    format_string=$(echo "${!valid_formats[@]}")
    [[ ! $(echo " $format_string " | grep " $format ") ]] && error_exit "Requested format $format is not supported.\nSupported formats: $format_string"
done

# Not really sure it makes a lot of sense to validate this ultimately, there are
# at least the following variations:
#   Digest: d9483ffe78b4
#   Name only: alpine
#   Name and tag: alpine:latest
#   Registry, name, tag: docker.io/alpine:latest
#   Names on the registry can have additional path components: docker.io/susedoc/ci:latest
[[ $(echo "$containername" | sed -r 's=^([-_.a-zA-Z0-9]+(/[-_.a-zA-Z0-9]+)*(:[-_.a-zA-Z0-9]+)?|[0-9a-f]+)==') ]] && error_exit "Container name \"$containername\" seems invalid."

[[ ! $(is_bool "$autoupdate") ]] && error_exit "Automatic container update parameter ($autoupdate) is not set to 0 or 1."

([[ $xsltparameterfile ]] && [[ ! -f $xsltparameterfile ]]) && error_exit "XSLT parameter file \"$xsltparameterfile\" does not exist."

([[ $dapsparameterfile ]] && [[ ! -f $dapsparameterfile ]]) && error_exit "DAPS parameter file \"$dapsparameterfile\" does not exist."

[[ ! $(is_bool "$debug") ]] && error_exit "Debug parameter ($debug) is not 0 or 1."

[[ ! $(is_bool "$autovalidate") ]] && error_exit "Automatic validation parameter ($autovalidate) is not 0 or 1."

[[ ! $(is_bool "$validatetables") ]] && error_exit "Table validation parameter ($validatetables) is not 0 or 1."

[[ ! $(is_bool "$createbigfile") ]] && error_exit "Bigfile creation parameter ($createbigfile) is not 0 or 1."

[[ ! $(is_bool "$createjsonfilelist") ]] && error_exit "filelist.json creation parameter ($createjsonfilelist) is not 0 or 1."

[[ ! $(is_bool "$info") ]] && error_exit "Extra information parameter ($info) is not 0 or 1."

if [[ ! $dcfiles ]]
  then
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

[[ $autoupdate -eq 1 ]] && "$container_engine" pull $containername

# Enable debugging with -g=1
[[ 1 -eq $debug ]] && daps="$daps --debug"

# If the container does not exist, this command will still output "[]", hence
# the sed. NB: We need to do this after the pull, as the pull might just
# produce the necessary image.
if [[ ! $("$container_engine" image inspect $containername 2>/dev/null | sed 's/\[\]//') ]]
  then
    clean_temp
    error_exit "Container image $containername does not exist."
fi

# spawn a Daps container
container_id=$( \
  "$container_engine" run \
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
echo "[INFO] Container ID: $container_id"

# copy all directories plus DC-file from the sourcedir
# except the build/ dir (if present)

for sourcedir in "$dir"/*/
  do
    subdir=$(basename "$sourcedir")
    [[ $subdir = "build" ]] && continue
    mkdir -p "$localsourcetempdir/$subdir"
    # NB: we're resolving symlinks here which is important especially for
    # translated documents
    cp -rL "$dir/$subdir/." "$localsourcetempdir/$subdir"
done
for dc in "$dir"/DC-*
  do
    if [[ -f "$dc" ]]
      then
        # NB: we're resolving symlinks here which is important especially for
        # translated documents
        cp -L "$dc" "$localsourcetempdir"
    fi
done

if [[ $info -eq 1 ]]
  then
    QUERYFORMAT='       - %{NAME}: %{VERSION}\n'
    echo "[INFO] Package versions in container:"
    "$container_engine" exec $container_id rpm -q --qf "$QUERYFORMAT" \
      daps ditaa \
      libxslt-tools libxml2-tools xmlgraphics-fop xmlstarlet \
      docbook_5 docbook_4 geekodoc novdoc \
      docbook-xsl-stylesheets docbook5-xsl-stylesheets \
      suse-xsl-stylesheets suse-xsl-stylesheets-sbp hpe-xsl-stylesheets \
      libxml2-tools libxslt-tools jing \
      google-noto-sans-{jp,kr,sc,tc}-{regular,bold}-fonts

    # We don't rely here on a specific name (like ruby2.5-rubygem-asciidoctor)
    # which can change in the future.
    "$container_engine" exec $container_id rpm -q \
       --qf "$QUERYFORMAT" --whatprovides "rubygem(asciidoctor)"
fi

# check whether we can/have to disable table validation (DAPS 3.3.0 is the first
# version that shipped with it, DAPS 3.3.1 first shipped the parameter to
# disable table validation everywhere; DAPS 3.3.0 is thus somewhat incompatible)
table_valid_param=''
daps_version_table_min=3.3.1
daps_version=$("$container_engine" exec "$container_id" rpm -q --qf '%{VERSION}' daps)
[[ "$validatetables" -eq 0 && \
  $(echo -e "$daps_version_table_min\n$daps_version" | sort --version-sort | head -1) = "$daps_version_table_min" ]] && \
  table_valid_param='--not-validate-tables'

# build output formats
filelist=''
filelist_json=''
for dc_file in $dcfiles
  do
    dm="-d"
    [[ ! $(echo "$dc_file" | sed -r 's/^(xml|adoc)\///') ]] && dm="-m"
    echo "[INFO] Building $dc_file"

    # This should be in there anyway, we just write it again just in case the
    # container author has forgotten it.
    echo 'DOCBOOK5_RNG_URI="https://github.com/openSUSE/geekodoc/raw/master/geekodoc/rng/geekodoc5-flat.rnc"' > $localtempdir/d2d-dapsrc-geekodoc
    echo 'DOCBOOK5_RNG_URI="file:///usr/share/xml/docbook/schema/rng/5.1/docbookxi.rng"' > $localtempdir/d2d-dapsrc-db51

    validation=
    validation_code=0
    if [[ "$autovalidate" -ne 0 ]]
      then
      "$container_engine" cp $localtempdir/d2d-dapsrc-geekodoc $container_id:/root/.config/daps/dapsrc

      validation=$("$container_engine" exec $container_id $daps $dm $containersourcetempdir/$dc_file validate "$table_valid_param" 2>&1)
      validation_code=$?

      validation_attempts=1
        if [[ "$validation_code" -gt 0 ]]
          then
            # Try again but with the DocBook upstream
            "$container_engine" cp $localtempdir/d2d-dapsrc-db51 $container_id:/root/.config/daps/dapsrc
            validation=$("$container_engine" exec $container_id $daps $dm $containersourcetempdir/$dc_file validate "$table_valid_param" 2>&1)
            validation_code=$?
            validation_attempts=2
        fi
      else
        # Make sure we are not using GeekoDoc in this case, to provoke lowest
        # number of build failures
        "$container_engine" cp $localtempdir/d2d-dapsrc-db51 $container_id:/root/.config/daps/dapsrc
    fi
    if [[ "$validation_code" -gt 0 ]]
      then
        echo -e "$validation"
        clean_temp
        json_line "$dc_file" "validate" "failed"
        format_filelists
        error_exit "$dc_file has validation issues and cannot be built."
      else
        json_line "$dc_file" "validate" "succeeded"
        [[ $validation_attempts -gt 1 ]] && echo "$dc_file has validation issues when trying to validate with GeekoDoc. It validates with DocBook though. Results might not look ideal."
        for format in $formats
          do
            format_subcommand="$format"
            [[ $format == 'single-html' ]] && format_subcommand='html --single'
            dapsparameters=
            xsltparameters=
            [[ $dapsparameterfile ]] && dapsparameters+=$(build_dapsparameters $dapsparameterfile $format_subcommand)
            [[ $xsltparameterfile ]] && xsltparameters+=$(build_xsltparameters $xsltparameterfile)
            echo -e "$daps $dm $containersourcetempdir/$dc_file $format_subcommand $dapsparameters $xsltparameters"
            output=$("$container_engine" exec $container_id $daps $dm $containersourcetempdir/$dc_file $format_subcommand "$table_valid_param" $dapsparameters $xsltparameters)
            build_code=$?
            if [[ "$build_code" -gt 0 ]]
              then
                clean_temp
                json_line "$dc_file" "$format" "failed"
                format_filelists
                error_exit "For $dc_file, the output format $format cannot be built. Exact message:\n\n$output\n"
            else
                output_path=$(echo "$output" | sed -r -e "s#^$containersourcetempdir/build#$outdir#")
                filelist+="$output_path "
                json_line "$dc_file" "$format" "succeeded" "$output_path"

                # FIXME: The --create-bigfile option is used by Docserv2
                # which also uses the DAPS/XSLT parameter file options which
                # are incompatible with building multiple formats at once
                # currently. This handling is slightly ugly, it might be
                # better to allow format-specific parameter files.

                # Let's just assume that we can always build a bigfile if we can
                # build regular output.
                if [[ $createbigfile -eq 1 ]]
                  then
                    output=$($container_engine exec $container_id $daps $dm $containersourcetempdir/$dc_file bigfile "$table_valid_param")
                    output_path=$(echo "$output" | sed -r -e "s#^$containersourcetempdir/build#$outdir#")
                    filelist+="$output_path "
                    json_line "$dc_file" "bigfile" "succeeded" "$output_path"
                fi
            fi
        done
    fi
done

# copy the finished product to final directory
mkdir -p $outdir
cp -r $localsourcetempdir/build/. $outdir
format_filelists

[[ user_change -eq 1 ]] && chown -R $user $outdir

# clean up
clean_temp
stop_container
