#!/usr/bin/env sh

# Check and source environment variable(s) generated by discovery service
test -f "${STAGING_DIR}/ds_env_vars" && . "${STAGING_DIR}/ds_env_vars"

########################################################################################################################
# Stop PingAccess server and wait until it is terminated.
#
########################################################################################################################
function stop_server()
{
  SERVER_PID=$(pgrep -f java)
  kill "${SERVER_PID}"
  while true; do
    SERVER_PID=$(pgrep -f java)
    if test -z ${SERVER_PID}; then
        break
    else
      beluga_log "Waiting for PingAccess to terminate"
      sleep 3
    fi
  done
}

########################################################################################################################
# Makes curl request to PingAccess API using the PA_ADMIN_USER_PASSWORD environment variable.
#
########################################################################################################################
function make_api_request() {
    set +x
    http_code=$(curl -sSk -o ${OUT_DIR}/api_response.txt -w "%{http_code}" \
         --retry ${API_RETRY_LIMIT} \
         --max-time ${API_TIMEOUT_WAIT} \
         --retry-delay 1 \
         --retry-connrefused \
         -u ${PA_ADMIN_USER_USERNAME}:${PA_ADMIN_USER_PASSWORD} \
         -H "X-Xsrf-Header: PingAccess " "$@")
    curl_result=$?
    "${VERBOSE}" && set -x

    if test "${curl_result}" -ne 0; then
        beluga_error "Admin API connection refused with the curl exit code: ${curl_result}"
        return 1
    fi

    if test "${http_code}" -ne 200; then
        beluga_log "API call returned HTTP status code: ${http_code}"
        cat ${OUT_DIR}/api_response.txt && rm -f ${OUT_DIR}/api_response.txt
        return 1
    fi

    cat ${OUT_DIR}/api_response.txt && rm -f ${OUT_DIR}/api_response.txt
    echo ""

    return 0
}

########################################################################################################################
# Makes curl request to PingAccess API using the '2Access' password.
#
########################################################################################################################
function make_initial_api_request() {
    set +x
    http_code=$(curl -sSk -o ${OUT_DIR}/api_response.txt -w "%{http_code}" \
         --retry ${API_RETRY_LIMIT} \
         --max-time ${API_TIMEOUT_WAIT} \
         --retry-delay 1 \
         --retry-connrefused \
         -u ${PA_ADMIN_USER_USERNAME}:${OLD_PA_ADMIN_USER_PASSWORD} \
         -H 'X-Xsrf-Header: PingAccess' "$@")
    curl_result=$?
    "${VERBOSE}" && set -x

    if test "${curl_result}" -ne 0; then
        beluga_log "Admin API connection refused"
        return 1
    fi

    if test "${http_code}" -ne 200; then
        beluga_log "API call returned HTTP status code: ${http_code}"
        return 1
    fi

    cat ${OUT_DIR}/api_response.txt && rm -f ${OUT_DIR}/api_response.txt

    return 0
}

########################################################################################################################
# Used for API calls that specify an output file.
# When using this function the existence of the output file
# should be used to verify this function succeeded.
#
########################################################################################################################
function make_api_request_download() {
    set +x
    http_code=$(curl -sSk -w "%{http_code}" \
         --retry ${API_RETRY_LIMIT} \
         --max-time ${API_TIMEOUT_WAIT} \
         --retry-delay 1 \
         --retry-connrefused \
         -u ${PA_ADMIN_USER_USERNAME}:${PA_ADMIN_USER_PASSWORD} \
         -H "X-Xsrf-Header: PingAccess " "$@")
    curl_result=$?
    "${VERBOSE}" && set -x

    if test "${curl_result}" -ne 0; then
        beluga_log "Admin API connection refused"
        return 1
    fi

    if test "${http_code}" -ne 200; then
        beluga_log "API call returned HTTP status code: ${http_code}"
        return 1
    fi

    return 0
}

########################################################################################################################
# Makes curl request to localhost PingAccess admin Console heartbeat page.
# If request fails, wait for 3 seconds and try again.
#
# Arguments
#   ${1} -> Optional host:port. Defaults to localhost:9000
########################################################################################################################
function pingaccess_admin_wait() {
    HOST_PORT="${1:-localhost:9000}"
    beluga_log "Waiting for admin server at ${HOST_PORT}"
    while true; do
        curl -ss --silent -o /dev/null -k https://"${HOST_PORT}"/pa/heartbeat.ping
        if ! test $? -eq 0; then
            beluga_log "Admin server not started, waiting.."
            sleep 3
        else
            beluga_log "Admin server started"
            break
        fi
    done
}

# A function to help with unit
# test mocking.  Please do not
# delete!
function inject_template() {
  echo $(envsubst < ${1})
  return $?;
}

########################################################################################################################
# Function to change password.
#
########################################################################################################################
function changePassword() {

  # Validate before attempting to change password
  set +x
  if test -z "${OLD_PA_ADMIN_USER_PASSWORD}" || test -z "${PA_ADMIN_USER_PASSWORD}"; then
    isPasswordEmpty=1
  else
    isPasswordEmpty=0
  fi
  if test "${OLD_PA_ADMIN_USER_PASSWORD}" = "${PA_ADMIN_USER_PASSWORD}"; then
    isPasswordSame=1
  else
    isPasswordSame=0
  fi
  "${VERBOSE}" && set -x

  if test ${isPasswordEmpty} -eq 1; then
    beluga_log "The old and new passwords cannot be blank"
    return 1
  elif test ${isPasswordSame} -eq 1; then
    beluga_log "old password and new password are the same, therefore cannot update password"
    return 1
  else
    # Change the default password.
    # Using set +x to suppress shell debugging
    # because it reveals the new admin password
    set +x
    change_password_payload=$(inject_template ${STAGING_DIR}/templates/81/change_password.json)
    make_initial_api_request -s -X PUT \
        -d "${change_password_payload}" \
        "https://localhost:9000/pa-admin-api/v3/users/1/password" > /dev/null
    CHANGE_PASSWORD_STATUS=${?}
    "${VERBOSE}" && set -x

    beluga_log "password change status: ${CHANGE_PASSWORD_STATUS}"

    # If no error, write password to disk
    if test ${CHANGE_PASSWORD_STATUS} -eq 0; then
      createSecretFile
      return 0
    fi

    beluga_log "error changing password"
    return 1
  fi
}

########################################################################################################################
# Function to read password within ${OUT_DIR}/secrets/pa-admin-password.
#
########################################################################################################################
function readPasswordFromDisk() {
  set +x
  # if file doesn't exist return empty string
  if ! test -f ${OUT_DIR}/secrets/pa-admin-password; then
    echo ""
  else
    password=$( cat ${OUT_DIR}/secrets/pa-admin-password )
    echo ${password}
  fi
  "${VERBOSE}" && set -x
  return 0
}

########################################################################################################################
# Function to write admin password to disk.
#
########################################################################################################################
function createSecretFile() {
  # make directory if it doesn't exist
  mkdir -p ${OUT_DIR}/secrets
  set +x
  echo "${PA_ADMIN_USER_PASSWORD}" > ${OUT_DIR}/secrets/pa-admin-password
  "${VERBOSE}" && set -x
  return 0
}

########################################################################################################################
# Compare password disk secret and desired value (environment variable).
# Print 0 if passwords dont match, print 1 if they are the same.
#
########################################################################################################################
function comparePasswordDiskWithVariable() {
  set +x
  # if from disk is different than the desired value return false
  if ! test "$(readPasswordFromDisk)" = "${PA_ADMIN_USER_PASSWORD}"; then
    echo 0
  else
    echo 1
  fi
  "${VERBOSE}" && set -x
  return 0
}

#########################################################################################################################
# Function sets required environment variables for skbn
#
########################################################################################################################
function initializeSkbnConfiguration() {
  unset SKBN_CLOUD_PREFIX
  unset SKBN_K8S_PREFIX

  # Allow overriding the backup URL with an arg
  test ! -z "${1}" && BACKUP_URL="${1}"

  # Check if endpoint is AWS cloud storage service (S3 bucket)
  case "$BACKUP_URL" in "s3://"*)

    # Set AWS specific variable for skbn
    export AWS_REGION=${REGION}

    DIRECTORY_NAME=$(echo "${PING_PRODUCT}" | tr '[:upper:]' '[:lower:]')

    if ! $(echo "$BACKUP_URL" | grep -q "/$DIRECTORY_NAME"); then
      BACKUP_URL="${BACKUP_URL}/${DIRECTORY_NAME}"
    fi

  esac

  beluga_log "Getting cluster metadata"

  # Get prefix of HOSTNAME which match the pod name.
  export POD="$(echo "${HOSTNAME}" | cut -d. -f1)"

  METADATA=$(kubectl get "$(kubectl get pod -o name --field-selector metadata.name=${POD})" \
    -o=jsonpath='{.metadata.namespace},{.metadata.name},{.metadata.labels.role}')

  METADATA_NS=$(echo "$METADATA"| cut -d',' -f1)
  METADATA_PN=$(echo "$METADATA"| cut -d',' -f2)
  METADATA_CN=$(echo "$METADATA"| cut -d',' -f3)

  # Remove suffix for runtime.
  METADATA_CN="${METADATA_CN%-engine}"

  export SKBN_CLOUD_PREFIX="${BACKUP_URL}"
  export SKBN_K8S_PREFIX="k8s://${METADATA_NS}/${METADATA_PN}/${METADATA_CN}"
}

########################################################################################################################
# Function to copy file(s) between cloud storage and k8s
#
########################################################################################################################
function skbnCopy() {
  PARALLEL="0"
  SOURCE="${1}"
  DESTINATION="${2}"

  # Check if the number of files to be copied in parallel is defined (0 for full parallelism)
  test ! -z "${3}" && PARALLEL="${3}"

  if ! skbn cp --src "$SOURCE" --dst "${DESTINATION}" --parallel "${PARALLEL}"; then
    return 1
  fi
}

########################################################################################################################
# Update the PA admin's host:port to be set in every engine's bootstrap.properties file.
########################################################################################################################
function update_admin_config_host_port() {
  local templates_dir_path="${STAGING_DIR}/templates/81"

  # Substitute the right values into the admin-config.json file based on single or multi cluster.
  admin_config_payload=$(envsubst < "${templates_dir_path}"/admin-config.json)

  admin_config_response=$(make_api_request -s -X PUT \
      -d "${admin_config_payload}" \
      "https://localhost:9000/pa-admin-api/v3/adminConfig")
}

########################################################################################################################
# Export values for PingAccess configuration settings based on single vs. multi cluster.
########################################################################################################################
function export_config_settings() {
  # First export environment variables based on PA or PA-WAS.
  export_environment_variables

  SHORT_HOST_NAME=$(hostname)
  ORDINAL=${SHORT_HOST_NAME##*-}

  if is_multi_cluster; then
    MULTI_CLUSTER=true
    export ENGINE_NAME="${ENGINE_PUBLIC_HOST_NAME}:300${ORDINAL}"
  else
    MULTI_CLUSTER=false
    export ENGINE_NAME=${SHORT_HOST_NAME}
  fi

  if is_secondary_cluster; then
    PRIMARY_CLUSTER=false
    export ADMIN_HOST_PORT="${CLUSTER_PUBLIC_HOSTNAME}:9000"
    export CLUSTER_CONFIG_HOST="${ADMIN_PUBLIC_HOST_NAME}"
  else
    PRIMARY_CLUSTER=true
    export ADMIN_HOST_PORT="${K8S_SERVICE_NAME_ADMIN}:9000"
    export CLUSTER_CONFIG_HOST="${K8S_SERVICE_NAME_ADMIN}"
  fi

  export CLUSTER_CONFIG_PORT=9090

  echo "MULTI_CLUSTER - ${MULTI_CLUSTER}"
  echo "PRIMARY_CLUSTER - ${PRIMARY_CLUSTER}"
  echo "ENGINE_NAME - ${ENGINE_NAME}"
  echo "CLUSTER_CONFIG_HOST_PORT - ${CLUSTER_CONFIG_HOST}:${CLUSTER_CONFIG_PORT}"
  echo "ADMIN_HOST_PORT - ${ADMIN_HOST_PORT}"
}

########################################################################################################################
# Determines if the environment is running in the context of multiple clusters.
#
# Returns
#   true if multi-cluster; false if not.
########################################################################################################################
function is_multi_cluster() {
  test ! -z "${IS_MULTI_CLUSTER}" && "${IS_MULTI_CLUSTER}"
}

########################################################################################################################
# Determines if the environment is set up in the primary cluster.
#
# Returns
#   true if primary cluster; false if not.
########################################################################################################################
function is_primary_cluster() {
  test "${TENANT_DOMAIN}" = "${PRIMARY_TENANT_DOMAIN}"
}

########################################################################################################################
# Determines if the environment is set up in a secondary cluster.
#
# Returns
#   true if secondary cluster; false if not.
########################################################################################################################
function is_secondary_cluster() {
  ! is_primary_cluster
}

########################################################################################################################
# Function to check if container is pingaccess-was
#
########################################################################################################################
function isPingaccessWas() {
  test "${K8S_STATEFUL_SET_NAME_PINGACCESS_WAS}"
}

########################################################################################################################
# Function to export different environment variables depending
# on if container is pingaccess-was or pingaccess
#
########################################################################################################################
function export_environment_variables() {

  # Common marker files
  export ADMIN_CONFIGURATION_COMPLETE="${SERVER_ROOT_DIR}/ADMIN_CONFIGURATION_COMPLETE"
  export POST_START_INIT_MARKER_FILE="${SERVER_ROOT_DIR}/post-start-init-complete"

  if isPingaccessWas; then
    export K8S_STATEFUL_SET_NAME="${K8S_STATEFUL_SET_NAME_PINGACCESS_WAS}"
    export K8S_SERVICE_NAME_ADMIN="${K8S_SERVICE_NAME_PINGACCESS_WAS_ADMIN}"

    export ADMIN_PUBLIC_HOST_NAME="${PA_WAS_ADMIN_PUBLIC_HOSTNAME}"
    export ENGINE_PUBLIC_HOST_NAME="${PA_WAS_ENGINE_PUBLIC_HOSTNAME}"

    export CLUSTER_PUBLIC_HOSTNAME="${PA_WAS_CLUSTER_PUBLIC_HOSTNAME}"

    export PA_DATA_BACKUP_URL="${BACKUP_URL}/pingaccess-was"
    export LOG_ARCHIVE_URL="${LOG_ARCHIVE_URL}/pingaccess-was"

    # If PA_WAS heap settings are defined, then prefer those over the PA ones.
    export PA_MIN_HEAP="${PA_WAS_MIN_HEAP:-${PA_MIN_HEAP}}"
    export PA_MAX_HEAP="${PA_WAS_MAX_HEAP:-${PA_MAX_HEAP}}"
    export PA_MIN_YGEN="${PA_WAS_MIN_YGEN:-${PA_MIN_YGEN}}"
    export PA_MAX_YGEN="${PA_WAS_MAX_YGEN:-${PA_MAX_YGEN}}"
    export PA_GCOPTION="${PA_WAS_GCOPTION:-${PA_GCOPTION}}"

    test -f "${STAGING_DIR}/p14c_env_vars" && source ${STAGING_DIR}/p14c_env_vars
  else
    export K8S_STATEFUL_SET_NAME="${K8S_STATEFUL_SET_NAME_PINGACCESS}"
    export K8S_SERVICE_NAME_ADMIN="${K8S_SERVICE_NAME_PINGACCESS_ADMIN}"

    export ADMIN_PUBLIC_HOST_NAME="${PA_ADMIN_PUBLIC_HOSTNAME}"
    export ENGINE_PUBLIC_HOST_NAME="${PA_ENGINE_PUBLIC_HOSTNAME}"

    export CLUSTER_PUBLIC_HOSTNAME="${PA_CLUSTER_PUBLIC_HOSTNAME}"

    export PA_DATA_BACKUP_URL=
  fi
}

########################################################################################################################
# Logs the provided message at the provided log level. Default log level is INFO, if not provided.
#
# Arguments
#   $1 -> The log message.
#   $2 -> Optional log level. Default is INFO.
########################################################################################################################
function beluga_log() {
  file_name="$(basename "$0")"
  message="$1"
  test -z "$2" && log_level='INFO' || log_level="$2"
  format='+%Y-%m-%d %H:%M:%S'
  timestamp="$(TZ=UTC date "${format}")"
  echo "${file_name}: ${timestamp} ${log_level} ${message}"
}

########################################################################################################################
# Logs the provided message and set the log level to ERROR.
#
# Arguments
#   $1 -> The log message.
########################################################################################################################
function beluga_error() {
  beluga_log "$1" 'ERROR'
}

########################################################################################################################
# Logs the provided message and set the log level to WARN.
#
# Arguments
#   $1 -> The log message.
########################################################################################################################
function beluga_warn() {
  beluga_log "$1" 'WARN'
}

########################################################################################################################
# Removes double quotes around string
#
########################################################################################################################
function strip_double_quotes() {
  local temp="${1%\"}"
  temp="${temp#\"}"
  echo "${temp}"
}

########################################################################################################################
# Format version for numeric comparison.
#
# Arguments
#   ${1} -> The version string, e.g. 10.0.0.
########################################################################################################################
format_version() {
  printf "%03d%03d%03d%03d" $(echo "${1}" | tr '.' ' ')
}

########################################################################################################################
# Get the version of the Pingaccess server in the provided directory.
#
# Arguments
#   ${1} -> The target directory containing server bits.
########################################################################################################################
get_version() {
  local target_dir="${1}"

  local scratch_dir=$(mktemp -d)
  find "${target_dir}" -name pingaccess-admin-ui*.jar | xargs -I {} cp {} "${scratch_dir}"

  cd "${scratch_dir}"
  unzip pingaccess-admin-ui*.jar &> /dev/null
  VERSION=$(grep version META-INF/maven/com.pingidentity.pingaccess/pingaccess-admin-ui/pom.properties | cut -d= -f2)
  cd - &> /dev/null
}

########################################################################################################################
# Get the version of the Pingaccess server packaged in the image.
########################################################################################################################
get_image_version() {
  get_version "${SERVER_BITS_DIR}"
  IMAGE_VERSION="${VERSION}"
}

########################################################################################################################
# Get the currently installed version of the Pingaccess server.
########################################################################################################################
get_installed_version() {
  get_version "${SERVER_ROOT_DIR}"
  INSTALLED_VERSION="${VERSION}"
}

########################################################################################################################
# Detects if this is a MyPing Deployment or not
########################################################################################################################
is_myping_deployment() {
  if test -z "${ENVIRONMENT_ID}"; then
    return 1
  else
    beluga_log "MyPing Deployment detected"
    return 0
  fi
}

########################################################################################################################
# Logs the contents of the provided file to stdout with a log level of INFO.
#
# Arguments
#   $1 -> The fully-qualified log filename.
#   $2 -> The optional log header.
########################################################################################################################
beluga_log_file_contents() {
  file="$1"
  log_header="${2:-'Contents of file'}"

  beluga_log "-----------------------------------------------------------------"
  beluga_log "${log_header}: ${filename}"
  beluga_log "-----------------------------------------------------------------"
  while IFS= read -r line; do
    beluga_log "${line}"
  done < ${file}
}

# These are needed by every script - so export them when this script is sourced.
beluga_log "export config settings"
export_config_settings

