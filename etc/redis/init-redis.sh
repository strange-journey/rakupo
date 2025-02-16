#!/bin/sh

awk '{ print "user default on ~* &* +@all >" $1 }' < /run/secrets/redis-pass > /data/users.acl
exec redis-server /usr/local/etc/redis/redis.conf
