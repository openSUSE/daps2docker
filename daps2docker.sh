#! /bin/sh

# daps2docker 
# A script which takes a daps build directory, loads it into a DAPS docker container builds it, and returns the directroy with the built docus.

# Looks if the directory exists
if [ $# -eq 0 ]
  then
    echo "No directory given, exiting."
    exit 1
fi



if [ -d $1 ]
  then
    echo "Directory found, checking if it has valid daps files."
    if [ -e $1/DC-* ]
      then
	      dc_file=$(ls $1 | grep 'DC-*')
	      echo "Found a valid daps config called: $dc_file"
      else
        echo "No valid daps config found, exiting gracefully..."
    fi
fi

# spawn a Daps container
docker run -d susedoc/ci:openSUSE-42.3 tail -f /dev/null

# check if spawn was successful
if [ $? -eq 0 ]
  then
    echo "Container successfully spawned, continue.."
  else
    echo "Error while spawning Container, exiting..."
fi

# first get the name of the container, then get the ID of the Daps container
docker_id=$(docker ps -aqf "ancestor=susedoc/ci:openSUSE-42.3" | head -1)
echo "Got Container ID: $docker_id"

# copy the Daps directory to the docker container
docker cp $1/. $docker_id:/daps_temp

# build HTML and PDF
docker exec $docker_id daps -d /daps_temp/$dc_file html
docker exec $docker_id daps -d /daps_temp/$dc_file pdf

# copy the finished product back to the host
docker cp $docker_id:/daps_temp ~/daps-finished

# stop the Daps container
docker stop $docker_id

