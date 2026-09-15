#!/bin/zsh
X=$(echo '{"id":"abc"}' | jq -r ".id")
echo "GOT:$X"
Y=$(echo hello | tr a-z A-Z)
echo "Y:$Y"
