#! /bin/sh

# daps2docker Docker Helper
# This script runs all the Docker-related commands, having this in a separate
# scripts makes it easier to run with root privileges

# $1 - name of original non-privileged user
# $2 - input dir
# $3 - output dir
# $4 - formats to build, comma-separated
# $5 - Docker container to use
# $6 - autoupdate Docker container? 1 (yes, default), 0 (no)
# $7 .. $x - DC files to build


error_exit() {
    # $1 - message string
    # $2 - error code (optional)
    echo -e "(Exiting helper) $1"
    stop_docker
    [[ $2 ]] && exit $2
    exit 1
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

stop_docker() {
    if [[ "$docker_id" ]]
      then
        # stop the Daps container
        docker stop $docker_id >/dev/null 2>/dev/null

        # we won't ever use the same container again, so remove the container's files
        docker rm $docker_id >/dev/null 2>/dev/null
    fi
}

user=$(whoami)
user_change=1
if [[ $1 == '!!no-user-change' ]]
  then
    user_change=0
  else
    user=$1
fi
shift

outdir=$1
shift

dir=$1
shift

formats=$(echo "$1" | sed 's/,/ /g')
shift

containername=$1
shift

autoupdate=$1
shift

dc_files=$*

# PAGER=cat means we avoid calling "less" here which would make it interactive
# and that is the last thing we want.
# FIXME: I am sure there is a better way to do this.
PAGER=cat systemctl status docker.service >/dev/null 2>/dev/null
service_status=$?
if [ $service_status -eq 3 ]
  then
    if [[ ! $(whoami) == 'root' ]]
      then
        echo "Docker service is not running. Give permission to start it."
        sudo systemctl start docker.service
      else
        systemctl start docker.service
    fi
  elif [ $service_status -gt 0 ]
    then
    error_exit "Issue with Docker service. Check 'systemctl status docker' yourself."
fi

[[ $autoupdate -eq 1 ]] && docker pull $containername

# If the container does not exist, this command will still output "[]", hence
# the sed. NB: We need to do this after the pull, as the pull might just
# produce the necessary image.
if [[ ! $(docker image inspect $containername 2>/dev/null | sed 's/\[\]//') ]]
  then
    error_exit "Container image $containername does not exist."
fi

# spawn a Daps container
docker run -d "$containername" tail -f /dev/null >/dev/null

# check if spawn was successful
if [ ! $? -eq 0 ]
  then
    error_exit "Error spawning container."
fi

# first get the name of the container, then get the ID of the Daps container
docker_id=$(docker ps -aqf "ancestor=$containername" | head -1)
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

# build HTML and PDF
filelist=''
for dc_file in $dc_files
  do
    echo "Building $dc_file"

    # This should be in there anyway, we just write it again just in case the
    # container author has forgotten it.
    echo 'DOCBOOK5_RNG_URI="https://github.com/openSUSE/geekodoc/raw/master/geekodoc/rng/geekodoc5-flat.rnc"' > /tmp/d2d-dapsrc-geekodoc
    echo 'DOCBOOK5_RNG_URI="file:///usr/share/xml/docbook/schema/rng/5.1/docbookxi.rng"' > /tmp/d2d-dapsrc-db51
    docker cp /tmp/d2d-dapsrc-geekodoc $docker_id:/root/.config/daps/dapsrc
    validation=$(docker exec $docker_id daps -d $temp_dir/$dc_file validate 2>&1)
    validation_attempts=1
    if [[ $(echo -e "$validation" | wc -l) -gt 1 ]]
      then
        # Try again but with the DocBook upstream
        docker cp /tmp/d2d-dapsrc-db51 $docker_id:/root/.config/daps/dapsrc
        validation=$(docker exec $docker_id daps -d $temp_dir/$dc_file validate 2>&1)
        validation_attempts=2
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
            output=$(docker exec $docker_id daps -d $temp_dir/$dc_file $format)
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
