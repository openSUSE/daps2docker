#! /bin/bash

# daps2docker Docker/Podman Helper
# This script runs all the Docker/Podman related commands, having this in a separate
# scripts makes it easier to run with root privileges

me=$(test -L $(realpath $0) && readlink $(realpath $0) || echo $(realpath $0))
mydir=$(dirname $me)

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
  echo "  -v=0/1                # validate before building? default: 1 (on)"
  echo "  -d=PARAMETER_FILE     # file with extra DAPS parameters"
  echo "  -x=PARAMETER_FILE     # file with extra XSLT processor parameters"
  echo "  -c=DOCKER_IMAGE       # container image for building"
  echo "  -u=0/1                # update container image? default: 1 (on)"
  echo "  -s=USER_NAME          # chown output files to this user"
  echo "  -n=0/1                # show extra information? default: 1 (on)"
  echo "  -b=0/1                # create bigfile additionally? default: 0 (off)"
  echo "  DC-FILE xml/MAIN_FILE.xml adoc/MAIN_FILE.adoc"
  echo "                        # DC/XML/AsciiDoc files to build from"
}

error_exit() {
    # $1 - message string
    # $2 - error code (optional)
    echo -e "(Exiting d2d_runner) $1"
    stop_container
    [[ $2 ]] && exit $2
    exit 1
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
    [[ $(echo "$paramlist_dropped" | sed -r 's/\s//g') ]] && >&2 echo "The following DAPS parameters are not supported either by DAPS or by daps2docker and have been dropped: $paramlist_dropped"
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

. $mydir/defaults

container_engine=${CONTAINER_ENGINE:-docker}

user=$(whoami)
user_change=0

dir=

outdir=

# $formats, v/ defaults

# $containername, v/ defaults
autoupdate=1

xsltparameterfile=
dapsparameterfile=

autovalidate=1

createbigfile=0

info=1

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
      -v=*|--auto-validate=*)
        autovalidate="${i#*=}"
      ;;
      -b=*|--create-bigfile=*)
        createbigfile="${i#*=}"
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

[[ $(echo "$containername" | sed -r 's=^([-_.a-zA-Z0-9]+/[-_.a-zA-Z0-9]+:[-_.a-zA-Z0-9]+|[0-9a-f]+)==') ]] && error_exit "Container name \"$containername\" seems invalid."

[[ ! $(is_bool "$autoupdate") ]] && error_exit "Automatic container update parameter ($autoupdate) is not set to 0 or 1."

([[ $xsltparameterfile ]] && [[ ! -f $xsltparameterfile ]]) && error_exit "XSLT parameter file \"$xsltparameterfile\" does not exist."

([[ $dapsparameterfile ]] && [[ ! -f $dapsparameterfile ]]) && error_exit "DAPS parameter file \"$dapsparameterfile\" does not exist."

[[ ! $(is_bool "$autovalidate") ]] && error_exit "Automatic validation parameter ($autovalidate) is not 0 or 1."

[[ ! $(is_bool "$createbigfile") ]] && error_exit "Bigfile creation parameter ($createbigfile) is not 0 or 1."

[[ ! $(is_bool "$info") ]] && error_exit "Extra information parameter ($autovalidate) is not 0 or 1."

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
echo "Container ID: $container_id"


# only copy the stuff we want -- not sure whether that saves any time, but it
# avoids copying the build dir (which avoids confusing users if there is
# something in it already: after the build we're copying the build dir back to
# the host and then having additional stuff there is ... confusing)

for subdir in "images/src" "adoc" "xml"
  do
    if [[ -d "$dir/$subdir" ]]
      then
        mkdir -p "$localsourcetempdir/$subdir"
        # NB: we're resolving symlinks here which is important especially for
        # translated documents
        cp -rL "$dir/$subdir/." "$localsourcetempdir/$subdir"
    fi
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
    echo "Package versions in container:"
    for dep in daps libxslt-tools libxml2-tools xmlgraphics-fop docbook-xsl-stylesheets docbook5-xsl-stylesheets suse-xsl-stylesheets suse-xsl-stylesheets-sbp hpe-xsl-stylesheets geekodoc novdoc
      do
        rpmstring=$("$container_engine" exec $container_id rpm -qi $dep)
        echo -n '  - '
        if [[ $(echo -e "$rpmstring" | head -1 | grep 'not installed') ]]
          then
            echo -n "$rpmstring"
          else
            echo "$rpmstring" | head -2 | awk '{print $3;}' | tr '\n' ' '
        fi
        echo ''
    done
fi

# build output formats
filelist=''
for dc_file in $dcfiles
  do
    dm="-d"
    [[ ! $(echo "$dc_file" | sed -r 's/^(xml|adoc)\///') ]] && dm="-m"
    echo "Building $dc_file"

    # This should be in there anyway, we just write it again just in case the
    # container author has forgotten it.
    echo 'DOCBOOK5_RNG_URI="https://github.com/openSUSE/geekodoc/raw/master/geekodoc/rng/geekodoc5-flat.rnc"' > $localtempdir/d2d-dapsrc-geekodoc
    echo 'DOCBOOK5_RNG_URI="file:///usr/share/xml/docbook/schema/rng/5.1/docbookxi.rng"' > $localtempdir/d2d-dapsrc-db51

    validation=
    if [[ "$autovalidate" -ne 0 ]]
      then
      "$container_engine" cp $localtempdir/d2d-dapsrc-geekodoc $container_id:/root/.config/daps/dapsrc

      validation=$("$container_engine" exec $container_id daps $dm $containersourcetempdir/$dc_file validate 2>&1)
      validation_attempts=1
        if [[ $(echo -e "$validation" | wc -l) -gt 1 ]]
          then
            # Try again but with the DocBook upstream
            "$container_engine" cp $localtempdir/d2d-dapsrc-db51 $container_id:/root/.config/daps/dapsrc
            validation=$("$container_engine" exec $container_id daps $dm $containersourcetempdir/$dc_file validate 2>&1)
            validation_attempts=2
        fi
      else
        # Make sure we are not using GeekoDoc in this case, to provoke lowest
        # number of build failures
        "$container_engine" cp $localtempdir/d2d-dapsrc-db51 $container_id:/root/.config/daps/dapsrc
    fi
    if [[ $(echo -e "$validation" | wc -l) -gt 1 ]]
      then
        echo -e "$validation"
        clean_temp
        error_exit "$dc_file has validation issues and cannot be built."
      else
        [[ $validation_attempts -gt 1 ]] && echo "$dc_file has validation issues when built with GeekoDoc. It validates with DocBook though. Results might not look ideal."
        for format in $formats
          do
            [[ $format == 'single-html' ]] && format='html --single'
            dapsparameters=
            xsltparameters=
            [[ $dapsparameterfile ]] && dapsparameters+=$(build_dapsparameters $dapsparameterfile $format)
            [[ $xsltparameterfile ]] && xsltparameters+=$(build_xsltparameters $xsltparameterfile)
            echo -e "daps $dm $containersourcetempdir/$dc_file $format $dapsparameters $xsltparameters"
            output=$("$container_engine" exec $container_id daps $dm $containersourcetempdir/$dc_file $format $dapsparameters $xsltparameters)
            if [[ $(echo -e "$output" | grep "Stop\.$") ]]
              then
                clean_temp
                error_exit "For $dc_file, the output format $format cannot be built. Exact message:\n\n$output\n"
            else
                # Let's just assume that we can always build a bigfile if we can
                # build regular output.
                [[ $createbigfile -eq 1 ]] && output+=" "$($container_engine exec $container_id daps $dm $containersourcetempdir/$dc_file bigfile)

                filelist+="$output "
            fi
        done
    fi
done

# copy the finished product to final directory
mkdir -p $outdir
cp -r $localsourcetempdir/build/. $outdir
if [[ "$filelist" ]]
  then
    echo "$filelist" | tr ' ' '\n' | sed -r -e "s#^$containersourcetempdir/build#$outdir#" >> $outdir/filelist
fi
[[ user_change -eq 1 ]] && chown -R $user $outdir

# clean up
clean_temp
stop_container
