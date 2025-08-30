#!/bin/sh

DEST_FOLDER="./release"
BIN_NAME="bragi"

mkdir -p $DEST_FOLDER

cd $DEST_FOLDER

odin build ../src -show-timings -use-separate-modules -out:$BIN_NAME -strict-style -vet-using-stmt -vet-using-param -vet-style -vet-semicolon -vet -o:speed

cd ..
