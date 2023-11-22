#!/bin/bash

mkdir web
chown 1000:1000 web
cp -n .env.template .env
cp -n .docker-compose.override.yml.template docker-compose.override.yml

DB_PW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32;)
DB_SU_PW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32;)

sed -i "s/GEN_DB_SU_PW/$DB_SU_PW/g" docker-compose.override.yml
sed -i "s/GEN_DB_PW/$DB_PW/g" docker-compose.override.yml
sed -i "s/GEN_DB_PW/$DB_PW/g" .env

echo ""
echo "VyHub onprem files have been initialized."
echo ""
echo "Save the following credentials for later if you want to access the database:"
echo ""
echo "Database user: vyhub"
echo "Database user password: $DB_PW"
echo ""
echo "Database superuser: postgres"
echo "Database superuser password: $DB_SU_PW"
echo ""
echo "Please continue with the instructions in the docs."
echo ""
