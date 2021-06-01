#!/bin/bash

script_to_test="${PROJECT_DIR}"/ci-scripts/test/integration/pingaccess/common-api/create-entity-operations.sh
. "${script_to_test}"

readonly resources_dir="${PROJECT_DIR}"/ci-scripts/test/unit/ci-script-tests/pingaccess/common-api/create-entity-operations/resources

# Mock this function call
curl() {
  create_vhost_200_response=$(cat "${resources_dir}"/create-vhost-200-response.txt)
  # echo into stdout as a return value
  echo "${create_vhost_200_response}"
  return 0
}

setUp() {
  # templates_dir_path must be exported into the env
  # for create_shared_secret to find the json file
  # it needs.
  export templates_dir_path="${PROJECT_DIR}"/ci-scripts/test/integration/pingaccess/templates
}

oneTimeTearDown() {
  unset templates_dir_path
}

testCreateVirtualHostHappyPath() {
  local http_ok_status_line='HTTP/1.1 200 OK'
  local name='"host":"localhost"'

  # curl is mocked above so these parameters don't matter
  create_vhost_response=$(create_virtual_host "" "" "")
  assertEquals "The function create_virtual_host returned a non-zero exit code.  The mocked curl function should force create_virtual_host to return 0." 0 $?
  assertContains "The create_vhost response \"${create_vhost_response}\" does not contain \"${http_ok_status_line}\"." "${create_vhost_response}" "${http_ok_status_line}"
  assertContains "The create_vhost response \"${create_vhost_response}\" does not contain \"${name}\"." "${create_vhost_response}" "${name}"
}

# load shunit
. ${SHUNIT_PATH}