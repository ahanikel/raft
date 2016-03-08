# Raft

An attempt to implement the Raft consensus protocol,
as described in https://ramcloud.stanford.edu/raft.pdf

# Build it

  stack build

# Run it

## In terminal window #1

  stack exec raft 127.0.0.1:9000 127.0.0.1:9001 127.0.0.1:9002

## In terminal window #2

  stack exec raft 127.0.0.1:9001 127.0.0.1:9000 127.0.0.1:9002

## In terminal window #3

  stack exec raft 127.0.0.1:9002 127.0.0.1:9000 127.0.0.1:9001
