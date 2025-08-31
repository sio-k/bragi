#!/bin/sh

DEST_FOLDER="./debug"
BIN_NAME="bragi_debug"
COMMAND="$1"
CONFIG="$2"

echo $COMMAND

if [ "$COMMAND" = 'clean' ]; then
   rm -rf $DEST_FOLDER
fi

mkdir -p $DEST_FOLDER

cd $DEST_FOLDER

odin build ../src -show-timings -use-separate-modules -out:$BIN_NAME -strict-style -vet-using-stmt -vet-using-param -vet-style -vet-semicolon -debug -vet -define:BRAGI_DEBUG=true

if [[ "$?" = 0 ]] && [[ "$COMMAND" = "run" ]]; then
    ./${BIN_NAME}
fi

cd ..
