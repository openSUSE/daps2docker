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
fi
