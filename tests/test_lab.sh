#!/usr/bin/env bash

set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lab.sh
source "${REPO_DIR}/lab.sh"

COLOUR_RED=''
COLOUR_GREEN=''
COLOUR_YELLOW=''
COLOUR_CYAN=''
COLOUR_RESET=''

PASS_COUNT=0

assert_contains() {
    local actual="$1"
    local expected="$2"
    local test_name="$3"

    if [[ "${actual}" != *"${expected}"* ]]; then
        printf 'FAIL: %s\nExpected output to contain: %s\nActual output:\n%s\n' \
            "${test_name}" "${expected}" "${actual}" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "${test_name}"
    PASS_COUNT=$((PASS_COUNT + 1))
}

aws_session_ready() { return 0; }

test_no_lab_status() {
    local output
    stack_exists() { return 1; }
    output="$(check_lab_status)"
    assert_contains "${output}" "No lab environment is currently deployed." "status without deployment"
}

test_duplicate_deployment_blocked() {
    local output
    stack_exists() { return 0; }
    output="$(deploy_lab)"
    assert_contains "${output}" "A lab environment already exists." "duplicate deployment prevention"
}

test_progressive_hints() {
    local test_state output_one output_two output_three
    test_state="$(mktemp -d)"
    STATE_DIR="${test_state}"
    HINT_FILE="${STATE_DIR}/hint-level"
    stack_exists() { return 0; }

    output_one="$(show_hint)"
    output_two="$(show_hint)"
    output_three="$(show_hint)"

    assert_contains "${output_one}" "Hint 1 of 3" "first progressive hint"
    assert_contains "${output_two}" "Hint 2 of 3" "second progressive hint"
    assert_contains "${output_three}" "Hint 3 of 3" "third progressive hint"
    rm -rf -- "${test_state}"
}

test_failed_verification_is_non_diagnostic() {
    local output
    stack_exists() { return 0; }
    stack_output() {
        [[ "$1" == "InstanceId" ]] && printf 'i-test123\n' || printf '203.0.113.10\n'
    }
    instance_state() { printf 'running\n'; }
    curl() {
        [[ "$*" == *"--write-out"* ]] && printf '000'
        return 1
    }

    output="$(verify_solution)"
    assert_contains "${output}" "RESULT: Not solved yet." "failed verification result"
    if [[ "${output}" == *"port 80"* || "${output}" == *"route table"* ]]; then
        printf 'FAIL: failed verification revealed a seeded fault\n' >&2
        exit 1
    fi
    printf 'PASS: failed verification does not reveal the solution\n'
    PASS_COUNT=$((PASS_COUNT + 1))
}

test_successful_verification() {
    local output
    stack_exists() { return 0; }
    stack_output() {
        [[ "$1" == "InstanceId" ]] && printf 'i-test123\n' || printf '203.0.113.10\n'
    }
    instance_state() { printf 'running\n'; }
    curl() {
        if [[ "$*" == *"--write-out"* ]]; then
            printf '200'
        else
            printf '<h1>AWS Foundation Troubleshooting Lab</h1>'
        fi
    }

    output="$(verify_solution)"
    assert_contains "${output}" "RESULT: Solution verified successfully!" "successful verification"
}

test_no_lab_status
test_duplicate_deployment_blocked
test_progressive_hints
test_failed_verification_is_non_diagnostic
test_successful_verification

printf '\nAll %s mocked workflow tests passed.\n' "${PASS_COUNT}"
