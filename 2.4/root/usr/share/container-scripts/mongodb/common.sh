#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Data directory where MongoDB database files live. The data subdirectory is here
# because mongodb.conf lives in /var/lib/mongodb/ and we don't want a volume to
# override it.
export MONGODB_DATADIR=/var/lib/mongodb/data
export CONTAINER_PORT=27017
# Configuration settings.
export MONGODB_NOPREALLOC=${MONGODB_NOPREALLOC:-true}
export MONGODB_SMALLFILES=${MONGODB_SMALLFILES:-true}
export MONGODB_QUIET=${MONGODB_QUIET:-true}
export MONGODB_TEXT_SEARCH_ENABLED=${MONGODB_TEXT_SEARCH_ENABLED:-false}

MONGODB_CONFIG_PATH=/etc/mongod.conf
MONGODB_KEYFILE_PATH="${HOME}/keyfile"

# Constants used for waiting
readonly MAX_ATTEMPTS=60
readonly SLEEP_TIME=1

# container_addr returns the current container external IP address
function container_addr() {
  echo -n $(cat ${HOME}/.address)
}

# mongo_addr returns the IP:PORT of the currently running MongoDB instance
function mongo_addr() {
  echo -n "$(container_addr):${CONTAINER_PORT}"
}

# cache_container_addr waits till the container gets the external IP address and
# cache it to disk
function cache_container_addr() {
  echo -n "=> Waiting for container IP address ..."
  local i
  for i in $(seq "$MAX_ATTEMPTS"); do
    if ip -oneline -4 addr show up scope global | grep -Eo '[0-9]{,3}(\.[0-9]{,3}){3}' > "${HOME}"/.address; then
      echo " $(mongo_addr)"
      return 0
    fi
    sleep $SLEEP_TIME
  done
  echo >&2 "Failed to get Docker container IP address." && exit 1
}

# wait_for_mongo_up waits until the mongo server accepts incomming connections
function wait_for_mongo_up() {
  _wait_for_mongo 1 "$@"
}

# wait_for_mongo_down waits until the mongo server is down
function wait_for_mongo_down() {
  _wait_for_mongo 0 "$@"
}

# wait_for_mongo waits until the mongo server is up/down
# $1 - 0 or 1 - to specify for what to wait (0 - down, 1 - up)
# $2 - host where to connect (localhost by default)
function _wait_for_mongo() {
  local operation=${1:-1}
  local message="up"
  if [[ ${operation} -eq 0 ]]; then
    message="down"
  fi

  local mongo_cmd="mongo admin --host ${2:-localhost} --port ${CONTAINER_PORT} "

  local i
  for i in $(seq $MAX_ATTEMPTS); do
    echo "=> ${2:-} Waiting for MongoDB daemon ${message}"
    if ([[ ${operation} -eq 1 ]] && ${mongo_cmd} --eval "quit()" &>/dev/null) || ([[ ${operation} -eq 0 ]] && ! ${mongo_cmd} --eval "quit()" &>/dev/null); then
      echo "=> MongoDB daemon is ${message}"
      return 0
    fi
    sleep ${SLEEP_TIME}
  done
  echo "=> Giving up: MongoDB daemon is not ${message}!"
  return 1
}

# endpoints returns list of IP addresses with other instances of MongoDB
# To get list of endpoints, you need to have headless Service named 'mongodb'.
# NOTE: This won't work with standalone Docker container.
function endpoints() {
  service_name=${MONGODB_SERVICE_NAME:-mongodb}
  dig ${service_name} A +search +short 2>/dev/null
}

# build_mongo_config builds the MongoDB replicaSet config used for the cluster
# initialization.
# Takes a list of space-separated member IPs as the first argument.
function build_mongo_config() {
  local current_endpoints
  current_endpoints="$1"
  local members
  members="{ _id: 0, host: \"$(mongo_addr)\"},"
  local member_id
  member_id=1
  local container_addr
  container_addr="$(container_addr)"
  local node
  for node in ${current_endpoints}; do
    if [ "$node" != "$container_addr" ]; then
      members+="{ _id: ${member_id}, host: \"${node}:${CONTAINER_PORT}\"},"
      let member_id++
    fi
  done
  echo -n "var config={ _id: \"${MONGODB_REPLICA_NAME}\", members: [ ${members%,} ] }"
}

# mongo_initiate initiates the replica set.
# Takes a list of space-separated member IPs as the first argument.
function mongo_initiate() {
  local mongo_wait
  mongo_wait="while (rs.status().startupStatus || (rs.status().hasOwnProperty(\"myState\") && rs.status().myState != 1)) { printjson( rs.status() ); sleep(1000); }; printjson( rs.status() );"
  config=$(build_mongo_config "$1")
  echo "=> Initiating MongoDB replica using: ${config}"
  mongo admin --eval "${config};rs.initiate(config);${mongo_wait}"
}

# replset_addr return the address of the current replSet
function replset_addr() {
  local current_endpoints
  current_endpoints="$(endpoints)"
  if [ -z "${current_endpoints}" ]; then
    echo >&2 "Cannot get address of replica set: no nodes are listed in service"
    return 1
  fi
  echo "${MONGODB_REPLICA_NAME}/${current_endpoints//[[:space:]]/,}"
}

# mongo_remove removes the current MongoDB from the cluster
function mongo_remove() {
  local host
  # if we cannot determine the IP address of the primary, exit without an error
  # to allow callers to proceed with their logic
  host="$(replset_addr || true)"
  if [ -z "$host" ]; then
    return
  fi

  local mongo_addr
  mongo_addr="$(mongo_addr)"

  echo "=> Removing ${mongo_addr} from replica set ..."
  mongo admin -u admin -p "${MONGODB_ADMIN_PASSWORD}" \
    --host "${host}" --eval "rs.remove('${mongo_addr}');" || true
}

# mongo_add advertise the current container to other mongo replicas
function mongo_add() {
  local host
  # if we cannot determine the IP address of the primary, exit without an error
  # to allow callers to proceed with their logic
  host="$(replset_addr || true)"
  if [ -z "$host" ]; then
    return
  fi

  local mongo_addr
  mongo_addr="$(mongo_addr)"

  echo "=> Adding ${mongo_addr} to replica set ..."
  mongo admin -u admin -p "${MONGODB_ADMIN_PASSWORD}" \
    --host "${host}" --eval "rs.add('${mongo_addr}');"
}

# mongo_create_admin creates the MongoDB admin user with password: MONGODB_ADMIN_PASSWORD
# $1 - login parameters for mongo (optional)
# $2 - host where to connect (localhost by default)
function mongo_create_admin() {
  if [[ -z "${MONGODB_ADMIN_PASSWORD:-}" ]]; then
    echo >&2 "=> MONGODB_ADMIN_PASSWORD is not set. Authentication can not be set up."
    exit 1
  fi

  # Set admin password
  local js_command="db.addUser({user: 'admin', pwd: '${MONGODB_ADMIN_PASSWORD}', roles: ['dbAdminAnyDatabase', 'userAdminAnyDatabase' , 'readWriteAnyDatabase','clusterAdmin' ]});"
  if ! mongo admin ${1:-} --host ${2:-"localhost"} --eval "${js_command}"; then
    echo >&2 "=> Failed to create MongoDB admin user."
    exit 1
  fi
}

# mongo_create_user creates the MongoDB database user: MONGODB_USER,
# with password: MONGDOB_PASSWORD, inside database: MONGODB_DATABASE
# $1 - login parameters for mongo (optional)
# $2 - host where to connect (localhost by default)
function mongo_create_user() {
  # Ensure input variables exists
  if [[ -z "${MONGODB_USER:-}" ]]; then
    echo >&2 "=> MONGODB_USER is not set. Failed to create MongoDB user"
    exit 1
  fi
  if [[ -z "${MONGODB_PASSWORD:-}" ]]; then
    echo >&2 "=> MONGODB_PASSWORD is not set. Failed to create MongoDB user: ${MONGODB_USER}"
    exit 1
  fi
  if [[ -z "${MONGODB_DATABASE:-}" ]]; then
    echo >&2 "=> MONGODB_DATABASE is not set. Failed to create MongoDB user: ${MONGODB_USER}"
    exit 1
  fi

  # Create database user
  local js_command="db.getSiblingDB('${MONGODB_DATABASE}').addUser({user: '${MONGODB_USER}', pwd: '${MONGODB_PASSWORD}', roles: [ 'readWrite' ]});"
  if ! mongo admin ${1:-} --host ${2:-"localhost"} --eval "${js_command}"; then
    echo >&2 "=> Failed to create MongoDB user: ${MONGODB_USER}"
    exit 1
  fi
}

# mongo_reset_user sets the MongoDB MONGODB_USER's password to match MONGODB_PASSWORD
function mongo_reset_user() {
  if [[ -n "${MONGODB_USER:-}" && -n "${MONGODB_PASSWORD:-}" && -n "${MONGODB_DATABASE:-}" ]]; then
    local js_command="db.changeUserPassword('${MONGODB_USER}', '${MONGODB_PASSWORD}')"
    if ! mongo ${MONGODB_DATABASE} --eval "${js_command}"; then
      echo >&2 "=> Failed to reset password of MongoDB user: ${MONGODB_USER}"
      exit 1
    fi
  fi
}

# mongo_reset_admin sets the MongoDB admin password to match MONGODB_ADMIN_PASSWORD
function mongo_reset_admin() {
  if [[ -n "${MONGODB_ADMIN_PASSWORD:-}" ]]; then
    local js_command="db.changeUserPassword('admin', '${MONGODB_ADMIN_PASSWORD}')"
    if ! mongo admin --eval "${js_command}"; then
      echo >&2 "=> Failed to reset password of MongoDB user: ${MONGODB_USER}"
      exit 1
    fi
  fi
}

# setup_keyfile fixes the bug in mounting the Kubernetes 'Secret' volume that
# mounts the secret files with 'too open' permissions.
# add --keyFile argument to mongo_common_args
function setup_keyfile() {
  # If user specify keyFile in config file do not use generated keyFile
  if grep -q "^\s*keyFile" ${MONGODB_CONFIG_PATH}; then
    exit 0
  fi
  if [ -z "${MONGODB_KEYFILE_VALUE-}" ]; then
    echo >&2 "ERROR: You have to provide the 'keyfile' value in MONGODB_KEYFILE_VALUE"
    exit 1
  fi
  local keyfile_dir
  keyfile_dir="$(dirname "$MONGODB_KEYFILE_PATH")"
  if [ ! -w "$keyfile_dir" ]; then
    echo >&2 "ERROR: Couldn't create ${MONGODB_KEYFILE_PATH}"
    echo >&2 "CAUSE: current user doesn't have permissions for writing to ${keyfile_dir} directory"
    echo >&2 "DETAILS: current user id = $(id -u), user groups: $(id -G)"
    echo >&2 "DETAILS: directory permissions: $(stat -c '%A owned by %u:%g' "${keyfile_dir}")"
    exit 1
  fi
  echo ${MONGODB_KEYFILE_VALUE} > ${MONGODB_KEYFILE_PATH}
  chmod 0600 ${MONGODB_KEYFILE_PATH}
  mongo_common_args+=" --keyFile ${MONGODB_KEYFILE_PATH}"
}
