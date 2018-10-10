#! /bin/bash

# daps2docker Docker Helper
# This script runs all the Docker-related commands, having this in a separate
# scripts makes it easier to run with root privileges

me=$(test -L $(realpath $0) && readlink $(realpath $0) || echo $(realpath $0))
mydir=$(dirname $me)

app_help() {
  echo "$0 / Build DAPS documentation in a Docker container (inner script)."
  echo "Unlike daps2docker itself, this script assumes a few things:"
  echo "  * the Docker service is running"
  echo "  * the current user is allowed to run Docker"
  echo "  * there is an empty output directory"
  echo "In exchange, you can run relatively arbitrary DAPS commands."
  echo ""
  echo "Parameters (* mandatory):"
  echo "  -i=INPUT_PATH         # *path to input directory"
  echo "  -o=OUTPUT_PATH        # *path to output directory (directory should be empty)"
  echo "  -f=FORMAT1[,FORMAT2]  # formats to build; recognized formats:"
  echo "$valid_formats" | fold -w 54 -s | sed 's/^/                          /'
  echo "  -v=0/1                # validate before building? default: 1 (on)"
  echo "  -d=PARAMETER_FILE     # file with extra DAPS parameters"
  echo "  -x=PARAMETER_FILE     # file with extra XSLT processor parameters"
  echo "  -c=DOCKER_IMAGE       # container image for building"
  echo "  -u=0/1                # update container image? default: 1 (on)"
  echo "  -s=USER_NAME          # chown output files to this user"
  echo "  -n=0/1                # show extra information? default: 1 (on)"
  echo "  DC-FILE xml/MAIN_FILE.xml adoc/MAIN_FILE.adoc"
  echo "                        # DC/XML/AsciiDoc files to build from"
}

error_exit() {
    # $1 - message string
    # $2 - error code (optional)
    echo -e "(Exiting d2d_runner) $1"
    stop_docker
    [[ $2 ]] && exit $2
    exit 1
}

is_bool() {
    # $1 - value to check for boolness
    [[ "$1" == 0 ]] && echo "isbool"
    [[ "$1" == 1 ]] && echo "isbool"
}

resolve_links() {
    dir="$1"
    glob="$2"
    docker_id="$3"
    docker_location="$4"
    links=$(find "$dir/$glob" -type l)
    if [[ "$links" ]]
      then
        len_path=$(echo "$dir/" | wc -c)
        for link in $links
          do
            real_file=$(readlink -e "$link")
            stripped_filename=$(echo "$link" | cut -b${len_path}-)
            # First delete those files, otherwise these will remain symlinks
            # (dangling ones at that)
            docker exec $docker_id rm "$docker_location/$stripped_filename"
            docker cp "$real_file" "$docker_id:$docker_location/$stripped_filename"
        done
    fi
}

build_xsltparameters() {
    # $1 - file to work from
    paramlist=
    cat $1 | while read param
      do
        paramlist+=" --stringparam='"$param"'"
    done
    echo "$paramlist"
}

stop_docker() {
    if [[ "$docker_id" ]]
      then
        # stop the Daps container
        docker stop $docker_id >/dev/null 2>/dev/null

        # we won't ever use the same container again, so remove the container's files
        docker rm $docker_id >/dev/null 2>/dev/null
    fi
}

. $mydir/defaults

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
        validation="${i#*=}"
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
    [[ ! $(echo " $valid_formats " | grep -P " $format ") ]] && error_exit "Requested format $format is not supported.\nSupported formats: $valid_formats"
done

[[ $(echo "$containername" | sed -r 's=^([-_.a-zA-Z0-9]+/[-_.a-zA-Z0-9]+:[-_.a-zA-Z0-9]+|[0-9a-f]+)==') ]] && error_exit "Container name \"$dir\" seems invalid."

[[ ! $(is_bool "$autoupdate") ]] && error_exit "Automatic container update parameter ($autoupdate) is not set to 0 or 1."

([[ $xsltparameterfile ]] && [[ ! -f $xsltparameterfile ]]) && error_exit "XSLT parameter file \"$xsltparameterfile\" does not exist."

([[ $dapsparameterfile ]] && [[ ! -f $dapsparameterfile ]]) && error_exit "DAPS parameter file \"$dapsparameterfile\" does not exist."

[[ ! $(is_bool "$autovalidate") ]] && error_exit "Automatic validation parameter ($autovalidate) is not set to 0 or 1."

[[ ! $(is_bool "$info") ]] && error_exit "Extra information parameter ($autovalidate) is not set to 0 or 1."

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

[[ $autoupdate -eq 1 ]] && docker pull $containername

# If the container does not exist, this command will still output "[]", hence
# the sed. NB: We need to do this after the pull, as the pull might just
# produce the necessary image.
if [[ ! $(docker image inspect $containername 2>/dev/null | sed 's/\[\]//') ]]
  then
    error_exit "Container image $containername does not exist."
fi

# spawn a Daps container
docker_id=$(docker run -d "$containername" tail -f /dev/null)

# check if spawn was successful
if [ ! $? -eq 0 ]
  then
    error_exit "Error spawning container."
fi

# first get the name of the container, then get the ID of the Daps container
echo "Container ID: $docker_id"

# copy the Daps directory to the docker container
temp_dir=/daps_temp
docker exec $docker_id rm -rf $temp_dir 2>/dev/null
docker exec $docker_id mkdir $temp_dir 2>/dev/null

# only copy the stuff we want -- not sure whether that saves any time, but it
# avoids copying the build dir (which avoids confusing users if there is
# something in it already: after the build we're copying the build dir back to
# the host and then having additional stuff there is ... confusing)
for subdir in images adoc xml
  do
    if [[ -d $dir/$subdir ]]
      then
        docker cp $dir/$subdir $docker_id:$temp_dir
        resolve_links "$dir" "$subdir" "$docker_id" "$temp_dir"
    fi
done
for dc in $dir/DC-*
  do
    if [[ -f $dc ]]
      then
        docker cp $dc $docker_id:$temp_dir
        # $dc includes the full path... hence, a $(basename)!
        resolve_links "$dir" $(basename "$dc") "$docker_id" "$temp_dir"
    fi
done

if [[ $info -eq 1 ]]
  then
    echo "Package versions in container:"
    for dep in daps daps-devel libxslt-tools libxml2-tools xmlgraphics-fop docbook-xsl-stylesheets docbook5-xsl-stylesheets suse-xsl-stylesheets hpe-xsl-stylesheets geekodoc novdoc
      do
        rpmstring=$(docker exec $docker_id rpm -qi $dep)
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

# build HTML and PDF
filelist=''
for dc_file in $dcfiles
  do
    dm="-d"
    [[ ! $(echo "$dc_file" | sed -r 's/^(xml|adoc)\///') ]] && dm="-m"
    echo "Building $dc_file"

    # This should be in there anyway, we just write it again just in case the
    # container author has forgotten it.
    echo 'DOCBOOK5_RNG_URI="https://github.com/openSUSE/geekodoc/raw/master/geekodoc/rng/geekodoc5-flat.rnc"' > /tmp/d2d-dapsrc-geekodoc
    echo 'DOCBOOK5_RNG_URI="file:///usr/share/xml/docbook/schema/rng/5.1/docbookxi.rng"' > /tmp/d2d-dapsrc-db51
    docker cp /tmp/d2d-dapsrc-geekodoc $docker_id:/root/.config/daps/dapsrc
    validation=$(docker exec $docker_id daps $dm $temp_dir/$dc_file validate 2>&1)
    validation_attempts=1
    if [[ "$autovalidate" -ne 0 ]]
      then
        if [[ $(echo -e "$validation" | wc -l) -gt 1 ]]
          then
            # Try again but with the DocBook upstream
            docker cp /tmp/d2d-dapsrc-db51 $docker_id:/root/.config/daps/dapsrc
            validation=$(docker exec $docker_id daps $dm $temp_dir/$dc_file validate 2>&1)
            validation_attempts=2
        fi
      else
        # Make sure we are not using GeekoDoc in this case, to provoke lowest
        # number of build failures
        docker cp /tmp/d2d-dapsrc-db51 $docker_id:/root/.config/daps/dapsrc
    fi
    if [[ $(echo -e "$validation" | wc -l) -gt 1 ]]
      then
        echo -e "$validation"
        error_exit "$dc_file has validation issues and cannot be built."
      else
        [[ $validation_attempts -gt 1 ]] && echo "$dc_file has validation issues when built with GeekoDoc. It validates with DocBook though. Results might not look ideal."
        for format in $formats
          do
            [[ $format == 'single-html' ]] && format='html --single'
            dapsparameters=
            [[ $dapsparameterfile ]] && dapsparameters+=$(cat $dapsparameterfile)
            [[ $xsltparameterfile ]] && dapsparameters+=$(build_xsltparameters $xsltparameterfile)
            output=$(docker exec $docker_id daps $dm $temp_dir/$dc_file $format $dapsparameters)
            if [[ $(echo -e "$output" | grep "Stop\.$") ]]
              then
                error_exit "For $dc_file, the output format $format cannot be built. Exact message:\n\n$output\n"
            else
                filelist+="$output "
            fi
        done
    fi
done

# copy the finished product back to the host
mkdir -p $outdir
docker cp $docker_id:$temp_dir/build/. $outdir
if [[ "$filelist" ]]
  then
    echo "$filelist" | tr ' ' '\n' | sed -r -e "s#^$temp_dir/build#$outdir#" >> $outdir/filelist
fi
[[ user_change -eq 1 ]] && chown -R $user $outdir

stop_docker
