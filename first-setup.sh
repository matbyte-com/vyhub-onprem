#!/bin/bash

# Exit if .env or docker-compose.override.yml already exist
if [ -f .env ] || [ -f docker-compose.override.yml ]; then
    echo "Setup has already been run. If you want to run it again, delete the files .env and docker-compose.override.yml and run this script again."
    exit 1
fi

mkdir web
chown 1000:1000 web

cp -n .env.template .env
cp -n .docker-compose.override.yml.template docker-compose.override.yml

DB_PW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32;)
DB_SU_PW=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32;)
SESSION_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64;)
CRYPT_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 64;)

sed -i "s/GEN_DB_SU_PW/$DB_SU_PW/g" docker-compose.override.yml
sed -i "s/GEN_DB_PW/$DB_PW/g" docker-compose.override.yml
sed -i "s/GEN_DB_PW/$DB_PW/g" .env
sed -i "s/GEN_SESSION_SECRET/$SESSION_SECRET/g" .env
sed -i "s/GEN_CRYPT_SECRET/$CRYPT_SECRET/g" .env

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
