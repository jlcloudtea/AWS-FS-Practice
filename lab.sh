#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/infra/template.yaml"
STATE_DIR="${SCRIPT_DIR}/.lab-state"
HINT_FILE="${STATE_DIR}/hint-level"
READY_FILE="${STATE_DIR}/ready"

AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-aws-foundation-troubleshooting-lab}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export AWS_PAGER=""

COLOUR_RED='\033[0;31m'
COLOUR_GREEN='\033[0;32m'
COLOUR_YELLOW='\033[0;33m'
COLOUR_CYAN='\033[0;36m'
COLOUR_RESET='\033[0m'

info() { printf "%b%s%b\n" "${COLOUR_CYAN}" "$*" "${COLOUR_RESET}"; }
success() { printf "%b%s%b\n" "${COLOUR_GREEN}" "$*" "${COLOUR_RESET}"; }
warning() { printf "%b%s%b\n" "${COLOUR_YELLOW}" "$*" "${COLOUR_RESET}"; }
error() { printf "%b%s%b\n" "${COLOUR_RED}" "$*" "${COLOUR_RESET}" >&2; }

pause() {
    printf "\nPress Enter to return to the menu..."
    read -r _
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "Required command not found: $1"
        return 1
    fi
}

aws_session_ready() {
    require_command aws || return 1

    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        error "AWS credentials are not active."
        printf "Start or restart your AWS Academy Learner Lab, then try again.\n"
        return 1
    fi
}

stack_status() {
    aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null
}

stack_exists() {
    local status
    status="$(stack_status)" || return 1
    [[ -n "${status}" && "${status}" != "None" && "${status}" != "DELETE_COMPLETE" ]]
}

stack_output() {
    local output_key="$1"
    aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue | [0]" \
        --output text 2>/dev/null
}

instance_state() {
    local instance_id="$1"
    aws ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null
}

website_http_code() {
    local url="$1"
    curl --connect-timeout 4 --max-time 8 --silent \
        --output /dev/null --write-out '%{http_code}' "${url}" 2>/dev/null || true
}

display_header() {
    local status="NOT DEPLOYED"
    local current_status

    if command -v aws >/dev/null 2>&1; then
        current_status="$(stack_status 2>/dev/null || true)"
        case "${current_status}" in
            CREATE_COMPLETE|UPDATE_COMPLETE)
                if [[ -f "${READY_FILE}" ]]; then
                    status="READY FOR TROUBLESHOOTING"
                else
                    status="DEPLOYED"
                fi
                ;;
            "") ;;
            *) status="${current_status}" ;;
        esac
    fi

    clear 2>/dev/null || true
    printf '%s\n' "========================================"
    printf '%s\n' " AWS Foundation Troubleshooting Lab"
    printf '%s\n' "========================================"
    printf " Region:     %s\n" "${AWS_REGION}"
    printf " Lab status: %s\n\n" "${status}"
    printf '%s\n' "1. Deploy Lab Environment"
    printf '%s\n' "2. Check Lab Status"
    printf '%s\n' "3. Show Web URL"
    printf '%s\n' "4. Get Troubleshooting Hints"
    printf '%s\n' "5. Verify My Solution"
    printf '%s\n' "6. Delete Lab Environment"
    printf '%s\n' "7. Exit"
    printf '\n'
}

wait_for_bootstrap() {
    local public_ip="$1"
    local attempt page

    info "[5/6] Waiting for the web server setup to finish..."
    for attempt in $(seq 1 36); do
        page="$(curl --connect-timeout 3 --max-time 5 --silent \
            "http://${public_ip}" 2>/dev/null || true)"
        if [[ "${page}" == *"AWS Foundation Troubleshooting Lab"* ]]; then
            return 0
        fi

        printf '.'
        sleep 10
    done
    printf '\n'
    return 1
}

seed_troubleshooting_faults() {
    local route_table_id="$1"
    local security_group_id="$2"

    info "[6/6] Preparing the troubleshooting scenario..."
    if ! aws ec2 revoke-security-group-ingress \
        --group-id "${security_group_id}" \
        --protocol tcp --port 80 --cidr '0.0.0.0/0' >/dev/null; then
        error "The lab was created, but its security-group scenario could not be prepared."
        return 1
    fi
    if ! aws ec2 authorize-security-group-ingress \
        --group-id "${security_group_id}" \
        --protocol tcp --port 880 --cidr '0.0.0.0/0' >/dev/null; then
        error "The lab was created, but its security-group scenario could not be prepared."
        return 1
    fi
    if ! aws ec2 delete-route \
        --route-table-id "${route_table_id}" \
        --destination-cidr-block '0.0.0.0/0' >/dev/null; then
        error "The lab was created, but the troubleshooting scenario could not be prepared."
        return 1
    fi
}

deploy_lab() {
    local instance_id route_table_id security_group_id public_ip

    printf '\n'
    info "Checking the AWS Academy environment..."
    aws_session_ready || return
    require_command curl || return

    if [[ ! -f "${TEMPLATE_FILE}" ]]; then
        error "CloudFormation template not found: ${TEMPLATE_FILE}"
        return
    fi

    if stack_exists; then
        warning "A lab environment already exists."
        printf "Use option 2 to check it or option 6 to delete it before deploying again.\n"
        return
    fi
    rm -f -- "${READY_FILE}"

    info "[1/6] Creating the VPC and subnets..."
    info "[2/6] Creating the Internet Gateway and route table..."
    info "[3/6] Creating the security group..."
    info "[4/6] Launching the EC2 web server..."

    if ! aws cloudformation deploy \
        --stack-name "${STACK_NAME}" \
        --template-file "${TEMPLATE_FILE}" \
        --tags Project=AWS-FS-Practice LabName="${STACK_NAME}" ManagedBy=CloudFormation \
        --no-fail-on-empty-changeset; then
        error "Deployment failed."
        printf "Review the recent CloudFormation events in the AWS console, then delete the failed stack.\n"
        return
    fi

    instance_id="$(stack_output InstanceId)"
    route_table_id="$(stack_output PublicRouteTableId)"
    security_group_id="$(stack_output SecurityGroupId)"
    public_ip="$(stack_output PublicIp)"

    if [[ -z "${instance_id}" || "${instance_id}" == "None" ]]; then
        error "Deployment completed, but the EC2 instance ID could not be found."
        return
    fi

    aws ec2 wait instance-status-ok --instance-ids "${instance_id}" || {
        error "The EC2 instance did not pass its status checks in time."
        return
    }

    if ! wait_for_bootstrap "${public_ip}"; then
        warning "The web server setup is taking longer than expected."
        printf "The network fault was not applied, so setup can continue.\n"
        printf "Wait two minutes, delete the lab, and deploy it again.\n"
        return
    fi
    printf '\n'

    seed_troubleshooting_faults "${route_table_id}" "${security_group_id}" || return
    mkdir -p "${STATE_DIR}"
    printf '0\n' > "${HINT_FILE}"
    printf 'ready\n' > "${READY_FILE}"

    printf '\n'
    success "Lab environment deployed successfully."
    printf "Instance: %s\n" "${instance_id}"
    printf "Public IP: %s\n" "${public_ip}"
    printf "The environment is ready for troubleshooting.\n"
}

check_lab_status() {
    local status instance_id state public_ip url code reachability

    printf '\n'
    aws_session_ready || return
    if ! stack_exists; then
        warning "No lab environment is currently deployed."
        printf "Choose option 1 to deploy it.\n"
        return
    fi

    status="$(stack_status)"
    instance_id="$(stack_output InstanceId)"
    public_ip="$(stack_output PublicIp)"
    state="$(instance_state "${instance_id}")"
    url="http://${public_ip}"
    code="$(website_http_code "${url}")"
    reachability="Not reachable"
    [[ "${code}" == "200" ]] && reachability="Reachable"

    printf '%s\n' "Lab environment status"
    printf '%s\n' "----------------------"
    printf "CloudFormation: %s\n" "${status}"
    printf "EC2 instance:   %s\n" "${state}"
    printf "Instance ID:    %s\n" "${instance_id}"
    printf "Public IP:      %s\n" "${public_ip}"
    printf "Website:        %s\n" "${reachability}"
}

show_web_url() {
    local public_ip

    printf '\n'
    aws_session_ready || return
    if ! stack_exists; then
        warning "No lab environment is currently deployed."
        printf "Choose option 1 to deploy it.\n"
        return
    fi

    public_ip="$(stack_output PublicIp)"
    if [[ -z "${public_ip}" || "${public_ip}" == "None" ]]; then
        warning "The instance does not currently have a public IP address."
        return
    fi

    printf "Web URL: http://%s\n" "${public_ip}"
    printf "Copy this URL into a new browser tab.\n"
    printf "If it does not open, begin troubleshooting the AWS environment.\n"
}

show_hint() {
    local level=0

    printf '\n'
    aws_session_ready || return
    if ! stack_exists; then
        warning "Deploy the lab before requesting a hint."
        return
    fi

    mkdir -p "${STATE_DIR}"
    if [[ -f "${HINT_FILE}" ]]; then
        read -r level < "${HINT_FILE}" || level=0
    fi
    [[ "${level}" =~ ^[0-9]+$ ]] || level=0

    case "${level}" in
        0)
            printf '%s\n' "Hint 1 of 3"
            printf '%s\n' "-----------"
            printf "Trace an internet request from the browser to the EC2 web server.\n"
            printf "Which AWS networking components must allow that request to pass?\n"
            level=1
            ;;
        1)
            printf '%s\n' "Hint 2 of 3"
            printf '%s\n' "-----------"
            printf "Apache normally serves HTTP traffic on TCP port 80.\n"
            printf "Compare that with the inbound rules assigned to the EC2 instance.\n"
            level=2
            ;;
        *)
            printf '%s\n' "Hint 3 of 3"
            printf '%s\n' "-----------"
            printf "Inspect the route table associated with the public subnet.\n"
            printf "Check whether internet-bound IPv4 traffic has a path to the Internet Gateway.\n"
            level=3
            ;;
    esac

    printf '%s\n' "${level}" > "${HINT_FILE}"
}

verify_solution() {
    local instance_id state public_ip url code body

    printf '\nChecking your solution...\n\n'
    aws_session_ready || return
    require_command curl || return

    if ! stack_exists; then
        warning "No lab environment is currently deployed."
        return
    fi

    instance_id="$(stack_output InstanceId)"
    public_ip="$(stack_output PublicIp)"
    state="$(instance_state "${instance_id}")"

    printf "EC2 instance:       %s\n" "${state}"
    if [[ -n "${public_ip}" && "${public_ip}" != "None" ]]; then
        printf "Public address:     Available\n"
    else
        printf "Public address:     Not available\n"
        printf "Website response:   Not reachable\n\n"
        warning "RESULT: Not solved yet."
        printf "Use option 4 if you would like a troubleshooting hint.\n"
        return
    fi

    url="http://${public_ip}"
    body="$(curl --connect-timeout 5 --max-time 10 --silent --show-error "${url}" 2>/dev/null || true)"
    code="$(website_http_code "${url}")"

    if [[ "${state}" == "running" && "${code}" == "200" && "${body}" == *"AWS Foundation Troubleshooting Lab"* ]]; then
        printf "Website response:   HTTP 200\n\n"
        success "RESULT: Solution verified successfully!"
        printf "The web server is now accessible from the internet.\n"
    else
        printf "Website response:   Not reachable\n\n"
        warning "RESULT: Not solved yet."
        printf "Continue tracing the connection from the internet to the web server.\n"
        printf "Use option 4 if you would like a troubleshooting hint.\n"
    fi
}

show_delete_failure() {
    error "The stack could not be deleted completely."
    printf "Most recent CloudFormation event:\n"
    aws cloudformation describe-stack-events \
        --stack-name "${STACK_NAME}" \
        --query 'StackEvents[0].[ResourceStatus,ResourceStatusReason]' \
        --output table 2>/dev/null || true
    printf "Open CloudFormation in %s to review the stack before trying again.\n" "${AWS_REGION}"
}

delete_lab() {
    local confirmation

    printf '\n'
    aws_session_ready || return
    if ! stack_exists; then
        warning "No lab environment was found. Nothing needs to be deleted."
        return
    fi

    warning "This will permanently delete the AWS Foundation lab environment."
    printf "Type DELETE to continue: "
    read -r confirmation
    if [[ "${confirmation}" != "DELETE" ]]; then
        printf "Deletion cancelled.\n"
        return
    fi

    info "Deleting the lab environment..."
    if ! aws cloudformation delete-stack --stack-name "${STACK_NAME}"; then
        show_delete_failure
        return
    fi

    if aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}"; then
        rm -f -- "${HINT_FILE}" "${READY_FILE}"
        rmdir -- "${STATE_DIR}" 2>/dev/null || true
        success "Lab environment deleted successfully."
        printf "No CloudFormation-managed lab resources remain.\n"
    else
        show_delete_failure
    fi
}

main() {
    local choice

    while true; do
        display_header
        printf "Select an option [1-7]: "
        read -r choice
        case "${choice}" in
            1) deploy_lab; pause ;;
            2) check_lab_status; pause ;;
            3) show_web_url; pause ;;
            4) show_hint; pause ;;
            5) verify_solution; pause ;;
            6) delete_lab; pause ;;
            7) printf "Exiting the lab. Remember to delete your environment when finished.\n"; exit 0 ;;
            *) warning "Please enter a number from 1 to 7."; pause ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
