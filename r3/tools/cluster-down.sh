#!/bin/bash
# Stop the kind node cleanly. The default 10 s docker timeout force-kills it (exit 137); 180 s lets systemd finish. Expected: about 90 s, exit 130.
docker stop -t 180 forge-spike-control-plane | cat
docker inspect forge-spike-control-plane --format 'status={{.State.Status}} exit={{.State.ExitCode}}' | cat
