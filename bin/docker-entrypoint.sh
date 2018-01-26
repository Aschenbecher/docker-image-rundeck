#!/bin/bash

set -e

chmod 1777 /tmp
#### chown stuff
if [[ -n "${RUNDECK_GID}" && -n "${RUNDECK_UID}" ]]; then
  echo "Setting rundeck account to ${RUNDECK_UID}:${RUNDECK_GID}"
  groupmod -o -g ${RUNDECK_GID} rundeck
  usermod -o -u ${RUNDECK_UID} -g ${RUNDECK_GID} rundeck
fi

# chown directories and files that might be coming from volumes
chown -R rundeck:rundeck /etc/rundeck
chown -R rundeck:rundeck /var/rundeck
chown -R rundeck:adm /var/log/rundeck
chown -R rundeck:rundeck /var/lib/rundeck
chown -R rundeck:rundeck /opt/rundeck-defaults
chown -R rundeck:rundeck /tmp/rundeck
chmod -R 750 /tmp/rundeck


initfile=/etc/rundeck.init
if [ ! -f "${initfile}" ]; then
  ############  initial configuration copy, once only

  # copy rundeck defaults
  if [ ! "$(ls -A /etc/rundeck)" ]; then
    cp -R /opt/rundeck-defaults/* /etc/rundeck
    chown -R rundeck:rundeck /etc/rundeck
  fi

  touch ${initfile}
fi

############## ensure mandatory things are set 
if [ -z "${EXTERNAL_SERVER_URL}" ]; then
  echo "please set the EXTERNAL_SERVER_URL env variable"
  exit 1
else
  SCHEME=$(echo ${EXTERNAL_SERVER_URL} | awk -F/ '{print $1}' | awk -F: '{print $1}')
  if [[ "${SCHEME}" != "http" && "${SCHEME}" != "https" ]]; then
    echo "please set the scheme like http:// or https:// in EXTERNAL_SERVER_URL env variable, like https://myrundeck.tld"
    exit 1
  fi
  sed -i 's,#\?grails.serverURL\=.*,grails.serverURL\='${EXTERNAL_SERVER_URL}',g' /etc/rundeck/rundeck-config.properties
fi

############## init variables / defaults
# try to check if we run encrypted or not
SERVER_PROTO=$(echo ${EXTERNAL_SERVER_URL} | awk -F/ '{print $1}' | awk -F: '{print $1}')
SERVER_HOSTNAME=localhost
if [ "${SERVER_PROTO}" == "http" ]; then
  SERVER_PORT=4440
else
  # used in profile of debians startup script to populate RDECK_JVM
  export RUNDECK_WITH_SSL=true
  SERVER_PORT=4443
fi

SERVER_URL="${SERVER_PROTO}://${SERVER_HOSTNAME}:${SERVER_PORT}"

# Docker secrets support
if [ -f /run/secrets/RUNDECK_PASSWORD ]; then
  RUNDECK_PASSWORD=$(< /run/secrets/RUNDECK_PASSWORD)
fi

if [ -f /run/secrets/KEYSTORE_PASS ]; then
  KEYSTORE_PASS=$(< /run/secrets/KEYSTORE_PASS)
fi
if [ -f /run/secrets/TRUSTSTORE_PASS ]; then
  TRUSTSTORE_PASS=$(< /run/secrets/TRUSTSTORE_PASS)
fi

if [ -z "${DB_TYPE}" ]; then
  echo "!!!! No DB_TYPE set, assuming you are running a default postgresql service named db with db rundeck on 5432"
  sleep 2
  DB_TYPE="postgresql"
  DB_HOST="db"
  DB_PORT="5432"
  DB_NAME="rundeck"
fi

DATABASE_URL="jdbc:${DB_TYPE}://${DB_HOST}:${DB_PORT}/${DB_NAME}?autoReconnect=true"
DB_PASSWORD=${DB_PASSWORD:-$(pwgen -s 15 1)}
DB_USER=${DB_USER:-rundeck}
RUNDECK_STORAGE_PROVIDER=${RUNDECK_STORAGE_PROVIDER:-"file"}
RUNDECK_PROJECT_STORAGE_TYPE=${RUNDECK_PROJECT_STORAGE_TYPE:-"file"}
LOGIN_MODULE=${LOGIN_MODULE:-"RDpropertyfilelogin"}
JAAS_CONF_FILE=${JAAS_CONF_FILE:-"jaas-loginmodule.conf"}
KEYSTORE_PASS=${KEYSTORE_PASS:-"adminadmin"}
TRUSTSTORE_PASS=${TRUSTSTORE_PASS:-${KEYSTORE_PASS}}

# Plugins
if ls /opt/rundeck-plugins/* 1> /dev/null 2>&1; then
   echo "=>Installing plugins from /opt/rundeck-plugins"
   cp -Rf /opt/rundeck-plugins/* /var/lib/rundeck/libext/
   chown -R rundeck:rundeck /var/lib/rundeck/libext
fi

echo "=>Initializing rundeck - This may take a few minutes"
if [ ! -f /var/lib/rundeck/.ssh/id_rsa ]; then
  echo "=>Generating rundeck key"
  sudo -u rundeck ssh-keygen -t rsa -b 4096 -f /var/lib/rundeck/.ssh/id_rsa -N ''
fi

if [ ! -f /etc/rundeck/ssl/truststore ]; then
  echo "=>Generating ssl cert"
  sudo -u rundeck mkdir -p /etc/rundeck/ssl
  if [ ! -f /etc/rundeck/ssl/keystore ]; then
      sudo -u rundeck keytool -importkeystore -destkeystore /etc/rundeck/ssl/keystore -srckeystore /etc/ssl/certs/java/cacerts -deststoretype JKS -srcstoretype JKS -deststorepass ${TRUSTSTORE_PASS} -srcstorepass changeit -noprompt > /dev/null
  fi
  sudo -u rundeck keytool -keystore /etc/rundeck/ssl/keystore -alias rundeck -genkey -keyalg RSA -keypass ${KEYSTORE_PASS} -storepass ${TRUSTSTORE_PASS} -dname "cn=localhost, o=OME, c=DE"
    cp /etc/rundeck/ssl/keystore /etc/rundeck/ssl/truststore
fi

# framework.properties
sed -i 's,framework.server.name\ \=.*,framework.server.name\ \=\ '${SERVER_HOSTNAME}',g' /etc/rundeck/framework.properties
sed -i 's,framework.server.hostname\ \=.*,framework.server.hostname\ \=\ '${SERVER_HOSTNAME}',g' /etc/rundeck/framework.properties
sed -i 's,framework.server.port\ \=.*,framework.server.port\ \=\ '${SERVER_PORT}',g' /etc/rundeck/framework.properties
sed -i 's,framework.server.url\ \=.*,framework.server.url\ \=\ '${SERVER_URL}',g' /etc/rundeck/framework.properties

# database
sed -i 's,dataSource.dbCreate.*,,g' /etc/rundeck/rundeck-config.properties
sed -i 's,dataSource.url = .*,dataSource.url = '${DATABASE_URL}',g' /etc/rundeck/rundeck-config.properties
if grep -q dataSource.username /etc/rundeck/rundeck-config.properties ; then
  :
else
  echo "dataSource.username = ${DB_USER}" >> /etc/rundeck/rundeck-config.properties
fi
if grep -q dataSource.password /etc/rundeck/rundeck-config.properties ; then
  sed -i 's,dataSource.password = .*,dataSource.password = '${DB_PASSWORD}',g' /etc/rundeck/rundeck-config.properties
else
  echo "dataSource.password = ${DB_PASSWORD}" >> /etc/rundeck/rundeck-config.properties
fi

# Check if we need to set the rundeck.gui.brand.html property
if [ -n "${GUI_BRAND_HTML}" ]; then
  if grep -q rundeck.gui.brand.html /etc/rundeck/rundeck-config.properties ; then
    sed -i 's/rundeck\.gui\.brand\.html.*$/rundeck\.gui\.brand\.html = '${GUI_BRAND_HTML}'/g' /etc/rundeck/rundeck-config.properties
  else
    echo "rundeck.gui.brand.html = ${GUI_BRAND_HTML}" >> /etc/rundeck/rundeck-config.properties
  fi
fi

# set the admin password
if [[ -n "${RUNDECK_ADMIN_PASSWORD}" ]]; then
  sed -i 's*^admin:admin,*admin:'${RUNDECK_ADMIN_PASSWORD}',*g' /etc/rundeck/realm.properties
  # If EXTERNAL_SERVER_URL is being used, the inside/outside ports for rundeck confuse the standard
  # CLI tools like rd-jobs, rd-project and they won't work.  You will need to use the new and improved
  # rundeck-cli tools.  To make the new CLI tools easier to use, go ahead and add an API token for the
  # admin account as a hash of the admin password.
  if [[ -n "${EXTERNAL_SERVER_URL}" ]]; then
    grep --silent "rundeck\.tokens\.file" /etc/rundeck/framework.properties || \
      echo "rundeck.tokens.file=/etc/rundeck/tokens.properties" >> /etc/rundeck/framework.properties
    mytoken=$(printf '%s' "${RUNDECK_ADMIN_PASSWORD}" | md5sum | cut -d ' ' -f 1)
    [[ -e /etc/rundeck/tokens.properties ]] \
      && grep --silent "^admin:" /etc/rundeck/tokens.properties \
      && sed -i -e "s,^admin:.*,admin: ${mytoken},g" /etc/rundeck/tokens.properties \
      || echo "admin: ${mytoken}" >> /etc/rundeck/tokens.properties
    chown rundeck:rundeck /etc/rundeck/tokens.properties
  fi
fi


#### STORAGE TYPES
if [ "${RUNDECK_STORAGE_PROVIDER}" == "db" ]; then
  echo "rundeck.storage.provider.1.type=db" >> /etc/rundeck/rundeck-config.properties
  echo "rundeck.storage.provider.1.path=/" >> /etc/rundeck/rundeck-config.properties
fi

if [ "${RUNDECK_PROJECT_STORAGE_TYPE}" == "db" ]; then
  echo "rundeck.projectsStorageType=db" >> /etc/rundeck/rundeck-config.properties
fi

#### MISC CONFIG
sed -i 's,JAAS_CONF\=.*,JAAS_CONF\="/etc/rundeck/'${JAAS_CONF_FILE}'",' /etc/rundeck/profile
sed -i 's,LOGIN_MODULE\=.*,LOGIN_MODULE\="'${LOGIN_MODULE}'",' /etc/rundeck/profile
sed -i 's,keystore\.password\=.*,keystore\.password\='${KEYSTORE_PASS}',' /etc/rundeck/ssl/ssl.properties
sed -i 's,key\.password\=.*,key\.password\='${TRUSTSTORE_PASS}',' /etc/rundeck/ssl/ssl.properties
sed -i 's,truststore\.password\=.*,truststore\.password\='${TRUSTSTORE_PASS}',' /etc/rundeck/ssl/ssl.properties
/custom-scripts.sh

echo "waiting for the database to come up"
wait-for-it -h ${DB_HOST} -p ${DB_PORT} -t 60 -- echo "db up"

echo -e "\n\n\n"
echo "==================================================================="
echo "Rundeck public key:"
cat /var/lib/rundeck/.ssh/id_rsa.pub

echo "Server URL set to ${EXTERNAL_SERVER_URL}"
echo "==================================================================="

sleep 1
echo "Starting rundesk"
/usr/bin/supervisord -c /etc/supervisor/conf.d/rundeck.conf
