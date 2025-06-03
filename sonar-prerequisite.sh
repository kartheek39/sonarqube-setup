#!/bin/bash


cd /mnt/

sudo rm -rf sonardb


sudo mkdir sonardb

sudo chown postgres:postgres sonardb


sudo rm -rf /var/lib/pgsql/data

