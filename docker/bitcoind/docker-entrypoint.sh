#!/bin/sh
set -e

if ! id bitcoin > /dev/null 2>&1; then
  USERID=${USERID:-1000}
  GROUPID=${GROUPID:-1000}

  groupadd -f -g $GROUPID bitcoin
  useradd -r -u $USERID -g $GROUPID bitcoin
  chown -R $USERID:$GROUPID /home/bitcoin
fi

if [ $(echo "$1" | cut -c1) = "-" ]; then
  set -- bitcoind "$@"
fi

if [ "$1" = "bitcoind" ] || [ "$1" = "bitcoin-cli" ] || [ "$1" = "bitcoin-tx" ]; then
  exec gosu bitcoin "$@"
fi

exec "$@"
