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

test_cleanup_role_override() {
    local output
    output="$(CLEANUP_ROLE_ARN='arn:aws:iam::123456789012:role/TestLabRole' resolve_cleanup_role_arn)"
    assert_contains "${output}" "arn:aws:iam::123456789012:role/TestLabRole" "cleanup role override"
}

test_automatic_cleanup_template() {
    local template
    template="$(<"${REPO_DIR}/infra/template.yaml")"
    assert_contains "${template}" "Type: AWS::Lambda::Function" "automatic cleanup Lambda"
    assert_contains "${template}" "Type: AWS::Events::Rule" "automatic cleanup schedule"
    assert_contains "${template}" "ScheduleExpression: rate(4 hours)" "four-hour cleanup limit"
    assert_contains "${template}" "boto3.client(\"cloudformation\").delete_stack" "automatic stack deletion"
    assert_contains "${template}" "Principal: events.amazonaws.com" "scheduled Lambda permission"
}

test_progressive_web_hints() {
    local test_state output_one output_two output_three
    test_state="$(mktemp -d)"
    STATE_DIR="${test_state}"
    WEB_HINT_FILE="${STATE_DIR}/web-hint-level"
    ASG_HINT_FILE="${STATE_DIR}/asg-hint-level"

    output_one="$(show_web_hint)"
    output_two="$(show_web_hint)"
    output_three="$(show_web_hint)"

    assert_contains "${output_one}" "Hint 1 of 3" "first web connectivity hint"
    assert_contains "${output_two}" "Hint 2 of 3" "second web connectivity hint"
    assert_contains "${output_three}" "Hint 3 of 3" "third web connectivity hint"
    rm -rf -- "${test_state}"
}

test_progressive_asg_hints() {
    local test_state output_one output_two output_three
    test_state="$(mktemp -d)"
    STATE_DIR="${test_state}"
    WEB_HINT_FILE="${STATE_DIR}/web-hint-level"
    ASG_HINT_FILE="${STATE_DIR}/asg-hint-level"

    output_one="$(show_asg_hint)"
    output_two="$(show_asg_hint)"
    output_three="$(show_asg_hint)"

    assert_contains "${output_one}" "Auto Scaling hint 1 of 3" "first Auto Scaling hint"
    assert_contains "${output_two}" "Auto Scaling hint 2 of 3" "second Auto Scaling hint"
    assert_contains "${output_three}" "Auto Scaling hint 3 of 3" "third Auto Scaling hint"
    rm -rf -- "${test_state}"
}

test_hint_category_menu() {
    local test_state output
    test_state="$(mktemp -d)"
    STATE_DIR="${test_state}"
    WEB_HINT_FILE="${STATE_DIR}/web-hint-level"
    ASG_HINT_FILE="${STATE_DIR}/asg-hint-level"
    stack_exists() { return 0; }

    output="$(printf '2\n' | show_hint_menu)"
    assert_contains "${output}" "Auto Scaling hint 1 of 3" "Auto Scaling hint menu selection"
    rm -rf -- "${test_state}"
}

mock_stack_outputs() {
    case "$1" in
        AutoScalingGroupName) printf 'asg-test\n' ;;
        ScalingPolicyName) printf 'policy-test\n' ;;
        HighCpuAlarmName) printf 'alarm-test\n' ;;
        AutomaticCleanup) printf 'Enabled - stack deletion starts four hours after deployment\n' ;;
        *) printf 'None\n' ;;
    esac
}

test_failed_verification_is_non_diagnostic() {
    local output
    stack_exists() { return 0; }
    stack_output() { mock_stack_outputs "$1"; }
    primary_asg_instance() { printf 'i-test123\n'; }
    instance_public_ip() { printf '203.0.113.10\n'; }
    instance_state() { printf 'running\n'; }
    aws() {
        case "$*" in
            *describe-auto-scaling-groups*) printf '1\t1\t2\t1\n' ;;
            *describe-policies*) printf 'SimpleScaling\tChangeInCapacity\t-1\tarn:policy-test\n' ;;
            *describe-alarms*) printf 'True\tarn:policy-test\n' ;;
        esac
    }
    curl() {
        [[ "$*" == *"--write-out"* ]] && printf '000'
        return 1
    }

    output="$(verify_solution)"
    assert_contains "${output}" "RESULT: Lab not completed yet." "failed verification result"
    assert_contains "${output}" "Scale-out policy:      FAIL" "incorrect policy detected"
    if [[ "${output}" == *"port 80"* || "${output}" == *"route table"* || "${output}" == *"-1"* ]]; then
        printf 'FAIL: failed verification revealed a seeded fault\n' >&2
        exit 1
    fi
    printf 'PASS: failed verification does not reveal the solution\n'
    PASS_COUNT=$((PASS_COUNT + 1))
}

test_policy_failure_after_website_repair() {
    local output
    stack_exists() { return 0; }
    stack_output() { mock_stack_outputs "$1"; }
    primary_asg_instance() { printf 'i-test123\n'; }
    instance_public_ip() { printf '203.0.113.10\n'; }
    instance_state() { printf 'running\n'; }
    aws() {
        case "$*" in
            *describe-auto-scaling-groups*) printf '1\t1\t2\t1\n' ;;
            *describe-policies*) printf 'SimpleScaling\tChangeInCapacity\t-1\tarn:policy-test\n' ;;
            *describe-alarms*) printf 'True\tarn:policy-test\n' ;;
        esac
    }
    curl() {
        if [[ "$*" == *"--write-out"* ]]; then
            printf '200'
        else
            printf '<h1>AWS Foundation Troubleshooting Lab</h1>'
        fi
    }

    output="$(verify_solution)"
    assert_contains "${output}" "Website connectivity:  PASS" "website repair accepted independently"
    assert_contains "${output}" "Scale-out policy:      FAIL" "remaining policy fault detected"
    assert_contains "${output}" "RESULT: Lab not completed yet." "policy fault blocks completion"
}

test_successful_verification() {
    local output
    stack_exists() { return 0; }
    stack_output() { mock_stack_outputs "$1"; }
    primary_asg_instance() { printf 'i-test123\n'; }
    instance_public_ip() { printf '203.0.113.10\n'; }
    instance_state() { printf 'running\n'; }
    aws() {
        case "$*" in
            *describe-auto-scaling-groups*) printf '1\t1\t2\t1\n' ;;
            *describe-policies*) printf 'SimpleScaling\tChangeInCapacity\t1\tarn:policy-test\n' ;;
            *describe-alarms*) printf 'True\tarn:policy-test\n' ;;
        esac
    }
    curl() {
        if [[ "$*" == *"--write-out"* ]]; then
            printf '200'
        else
            printf '<h1>AWS Foundation Troubleshooting Lab</h1>'
        fi
    }

    output="$(verify_solution)"
    assert_contains "${output}" "Website connectivity:  PASS" "successful website verification"
    assert_contains "${output}" "Scale-out policy:      PASS" "successful policy verification"
    assert_contains "${output}" "RESULT: All troubleshooting tasks completed successfully!" "successful overall verification"
}

test_no_lab_status
test_duplicate_deployment_blocked
test_cleanup_role_override
test_automatic_cleanup_template
test_progressive_web_hints
test_progressive_asg_hints
test_hint_category_menu
test_failed_verification_is_non_diagnostic
test_policy_failure_after_website_repair
test_successful_verification

printf '\nAll %s mocked workflow tests passed.\n' "${PASS_COUNT}"
