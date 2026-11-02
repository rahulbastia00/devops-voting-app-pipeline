#!/bin/bash
VOTE_URL="http://15.252.88.7:31000"

echo "Starting continuous voting traffic to $VOTE_URL..."
echo "Press [CTRL+C] to stop."

COUNT=0
while true; do
  # Send 5 parallel votes for 'a'
  curl -s -X POST -d "vote=a" "$VOTE_URL" > /dev/null &
  curl -s -X POST -d "vote=a" "$VOTE_URL" > /dev/null &
  
  # Send 5 parallel votes for 'b'
  curl -s -X POST -d "vote=b" "$VOTE_URL" > /dev/null &
  curl -s -X POST -d "vote=b" "$VOTE_URL" > /dev/null &
  
  wait
  COUNT=$((COUNT + 4))
  echo -ne "Total live votes dispatched: $COUNT\r"
  sleep 0.2
done
