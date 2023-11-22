#!/bin/bash

mkdir web
chown 1000:1000 web
cp -n .env.template .env
