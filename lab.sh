#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/infra/template.yaml"
STATE_DIR="${SCRIPT_DIR}/.lab-state"
WEB_HINT_FILE="${STATE_DIR}/web-hint-level"
ASG_HINT_FILE="${STATE_DIR}/asg-hint-level"
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

resolve_cleanup_role_arn() {
    local identity account_id caller_arn arn_label partition

    if [[ -n "${CLEANUP_ROLE_ARN:-}" ]]; then
        printf '%s\n' "${CLEANUP_ROLE_ARN}"
        return 0
    fi

    identity="$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null)" || return 1
    read -r account_id caller_arn <<< "${identity}"
    IFS=: read -r arn_label partition _ <<< "${caller_arn}"
    if [[ -z "${account_id}" || "${account_id}" == "None" || \
          "${arn_label}" != "arn" || -z "${partition}" ]]; then
        return 1
    fi

    printf 'arn:%s:iam::%s:role/LabRole\n' "${partition}" "${account_id}"
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

primary_asg_instance() {
    local asg_name="$1"
    aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "${asg_name}" \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' \
        --output text 2>/dev/null
}

asg_instance_ids() {
    local asg_name="$1"
    aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "${asg_name}" \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
        --output text 2>/dev/null
}

instance_public_ip() {
    local instance_id="$1"
    aws ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>/dev/null
}

website_http_code() {
    local url="$1"
    curl --connect-timeout 4 --max-time 8 --silent \
        --output /dev/null --write-out '%{http_code}' "${url}" 2>/dev/null || true
}

display_header() {
    local status="NOT DEPLOYED"
    local current_status auto_delete=""

    if command -v aws >/dev/null 2>&1; then
        current_status="$(stack_status 2>/dev/null || true)"
        case "${current_status}" in
            CREATE_COMPLETE|UPDATE_COMPLETE)
                if [[ -f "${READY_FILE}" ]]; then
                    status="READY FOR TROUBLESHOOTING"
                else
                    status="DEPLOYED"
                fi
                auto_delete="$(stack_output AutomaticCleanup 2>/dev/null || true)"
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
    printf " Lab status: %s\n" "${status}"
    if [[ -n "${auto_delete}" && "${auto_delete}" != "None" ]]; then
        printf " Auto-delete: %s\n" "${auto_delete}"
    fi
    printf '\n'
    printf '%s\n' "1. Deploy Lab Environment"
    printf '%s\n' "2. Check Lab Status"
    printf '%s\n' "3. Show Web URL"
    printf '%s\n' "4. Get Troubleshooting Hints"
    printf '%s\n' "5. Verify My Solution"
    printf '%s\n' "6. Delete Lab Environment"
    printf '%s\n' "7. Exit"
    printf '\n'
}

wait_for_asg_instance() {
    local asg_name="$1"
    local attempt instance_id

    for attempt in $(seq 1 30); do
        instance_id="$(primary_asg_instance "${asg_name}" || true)"
        if [[ -n "${instance_id}" && "${instance_id}" != "None" ]]; then
            printf '%s\n' "${instance_id}"
            return 0
        fi
        sleep 5
    done
    return 1
}

wait_for_bootstrap() {
    local public_ip="$1"
    local attempt page

    info "Waiting for the web server setup to finish..."
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
    local asg_name instance_id route_table_id security_group_id public_ip
    local cleanup_role_arn cleanup_description

    printf '\n'
    info "Checking the AWS Academy environment..."
    aws_session_ready || return 1
    require_command curl || return 1

    if [[ ! -f "${TEMPLATE_FILE}" ]]; then
        error "CloudFormation template not found: ${TEMPLATE_FILE}"
        return 1
    fi

    if stack_exists; then
        warning "A lab environment already exists."
        printf "Use option 2 to check it or option 6 to delete it before deploying again.\n"
        return 1
    fi
    rm -f -- "${READY_FILE}"

    cleanup_role_arn="$(resolve_cleanup_role_arn)" || {
        error "The AWS Academy LabRole ARN could not be determined."
        printf "Set CLEANUP_ROLE_ARN to a Lambda-compatible role ARN, then try again.\n"
        return 1
    }

    info "[1/7] Creating the VPC and subnets..."
    info "[2/7] Creating the Internet Gateway and route table..."
    info "[3/7] Creating the security group..."
    info "[4/7] Creating the Launch Template and Auto Scaling Group..."
    info "[5/7] Creating the high-CPU alarm, scaling policy, and four-hour cleanup timer..."

    if ! aws cloudformation deploy \
        --stack-name "${STACK_NAME}" \
        --template-file "${TEMPLATE_FILE}" \
        --parameter-overrides CleanupRoleArn="${cleanup_role_arn}" \
        --tags Project=AWS-FS-Practice LabName="${STACK_NAME}" ManagedBy=CloudFormation \
        --no-fail-on-empty-changeset; then
        error "Deployment failed."
        printf "Review the recent CloudFormation events in the AWS console, then delete the failed stack.\n"
        return 1
    fi

    asg_name="$(stack_output AutoScalingGroupName)"
    route_table_id="$(stack_output PublicRouteTableId)"
    security_group_id="$(stack_output SecurityGroupId)"

    if [[ -z "${asg_name}" || "${asg_name}" == "None" ]]; then
        error "Deployment completed, but the Auto Scaling Group could not be found."
        return 1
    fi

    info "[6/7] Waiting for the Auto Scaling web server to become ready..."
    instance_id="$(wait_for_asg_instance "${asg_name}")"
    if [[ -z "${instance_id}" || "${instance_id}" == "None" ]]; then
        error "The Auto Scaling Group did not produce an InService instance in time."
        return 1
    fi
    public_ip="$(instance_public_ip "${instance_id}")"
    if [[ -z "${public_ip}" || "${public_ip}" == "None" ]]; then
        error "The Auto Scaling instance does not have a public IP address."
        return 1
    fi

    aws ec2 wait instance-status-ok --instance-ids "${instance_id}" || {
        error "The EC2 instance did not pass its status checks in time."
        return 1
    }

    if ! wait_for_bootstrap "${public_ip}"; then
        warning "The web server setup is taking longer than expected."
        printf "The two network faults were not applied, so setup can continue.\n"
        printf "Wait two minutes, delete the lab, and deploy it again.\n"
        return 1
    fi
    printf '\n'

    info "[7/7] Applying the troubleshooting scenario..."
    seed_troubleshooting_faults "${route_table_id}" "${security_group_id}" || return 1
    mkdir -p "${STATE_DIR}"
    printf '0\n' > "${WEB_HINT_FILE}"
    printf '0\n' > "${ASG_HINT_FILE}"
    printf 'ready\n' > "${READY_FILE}"

    printf '\n'
    success "Lab environment deployed successfully."
    printf "Auto Scaling Group: %s\n" "${asg_name}"
    printf "Instance: %s\n" "${instance_id}"
    printf "Public IP: %s\n" "${public_ip}"
    cleanup_description="$(stack_output AutomaticCleanup)"
    printf "Automatic cleanup: %s\n" "${cleanup_description}"
    printf "The environment is ready for troubleshooting.\n"
    return 0
}

check_lab_status() {
    local status asg_name instance_id state public_ip url code reachability desired in_service
    local cleanup_description

    printf '\n'
    aws_session_ready || return
    if ! stack_exists; then
        warning "No lab environment is currently deployed."
        printf "Choose option 1 to deploy it.\n"
        return
    fi

    status="$(stack_status)"
    asg_name="$(stack_output AutoScalingGroupName)"
    instance_id="$(primary_asg_instance "${asg_name}")"
    state="Not available"
    public_ip="None"
    if [[ -n "${instance_id}" && "${instance_id}" != "None" ]]; then
        public_ip="$(instance_public_ip "${instance_id}")"
        state="$(instance_state "${instance_id}")"
    fi
    desired="$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "${asg_name}" \
        --query 'AutoScalingGroups[0].DesiredCapacity' --output text 2>/dev/null)"
    in_service="$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "${asg_name}" \
        --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService`])' \
        --output text 2>/dev/null)"
    cleanup_description="$(stack_output AutomaticCleanup)"
    reachability="Not reachable"
    if [[ -n "${public_ip}" && "${public_ip}" != "None" ]]; then
        url="http://${public_ip}"
        code="$(website_http_code "${url}")"
        [[ "${code}" == "200" ]] && reachability="Reachable"
    fi

    printf '%s\n' "Lab environment status"
    printf '%s\n' "----------------------"
    printf "CloudFormation: %s\n" "${status}"
    printf "Auto Scaling:   %s desired / %s InService\n" "${desired}" "${in_service}"
    printf "ASG name:       %s\n" "${asg_name}"
    printf "EC2 instance:   %s\n" "${state}"
    printf "Instance ID:    %s\n" "${instance_id}"
    printf "Public IP:      %s\n" "${public_ip}"
    printf "Website:        %s\n" "${reachability}"
    printf "Auto-delete:    %s\n" "${cleanup_description}"
}

show_web_url() {
    local asg_name instance_id instance_ids public_ip found=0
    local -a instance_array=()

    printf '\n'
    aws_session_ready || return
    if ! stack_exists; then
        warning "No lab environment is currently deployed."
        printf "Choose option 1 to deploy it.\n"
        return
    fi

    asg_name="$(stack_output AutoScalingGroupName)"
    instance_ids="$(asg_instance_ids "${asg_name}")"
    if [[ -z "${instance_ids}" || "${instance_ids}" == "None" ]]; then
        warning "The Auto Scaling Group has no InService instances."
        return
    fi

    printf "Auto Scaling Group: %s\n\n" "${asg_name}"
    read -r -a instance_array <<< "${instance_ids}"
    for instance_id in "${instance_array[@]}"; do
        public_ip="$(instance_public_ip "${instance_id}")"
        if [[ -n "${public_ip}" && "${public_ip}" != "None" ]]; then
            found=$((found + 1))
            printf "Instance %s\n" "${instance_id}"
            printf "Web URL: http://%s\n\n" "${public_ip}"
        fi
    done
    if [[ "${found}" -eq 0 ]]; then
        warning "No InService instance currently has a public IP address."
        return
    fi
    printf "Copy a URL into a new browser tab. If it does not open, begin troubleshooting.\n"
}

show_web_hint() {
    local level=0

    mkdir -p "${STATE_DIR}"
    if [[ -f "${WEB_HINT_FILE}" ]]; then
        read -r level < "${WEB_HINT_FILE}" || level=0
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

    printf '%s\n' "${level}" > "${WEB_HINT_FILE}"
}

show_asg_hint() {
    local level=0

    mkdir -p "${STATE_DIR}"
    if [[ -f "${ASG_HINT_FILE}" ]]; then
        read -r level < "${ASG_HINT_FILE}" || level=0
    fi
    [[ "${level}" =~ ^[0-9]+$ ]] || level=0

    case "${level}" in
        0)
            printf '%s\n' "Auto Scaling hint 1 of 3"
            printf '%s\n' "------------------------"
            printf "Trace the relationship between the high-CPU CloudWatch alarm,\n"
            printf "its scaling policy, and the Auto Scaling Group.\n"
            level=1
            ;;
        1)
            printf '%s\n' "Auto Scaling hint 2 of 3"
            printf '%s\n' "------------------------"
            printf "A high-CPU scale-out policy should increase the group's capacity.\n"
            printf "Inspect the action configured in the attached dynamic scaling policy.\n"
            level=2
            ;;
        *)
            printf '%s\n' "Auto Scaling hint 3 of 3"
            printf '%s\n' "------------------------"
            printf "For ChangeInCapacity, a positive value adds instances and a negative\n"
            printf "value removes instances. Correct the policy so it adds one instance.\n"
            level=3
            ;;
    esac

    printf '%s\n' "${level}" > "${ASG_HINT_FILE}"
}

show_hint_menu() {
    local choice

    printf '\n'
    aws_session_ready || return
    if ! stack_exists; then
        warning "Deploy the lab before requesting a hint."
        return
    fi

    printf '%s\n' "Troubleshooting Hints"
    printf '%s\n' "---------------------"
    printf '%s\n' "1. Web Connectivity Hint"
    printf '%s\n' "2. Auto Scaling Hint"
    printf '%s\n' "3. Return to Main Menu"
    printf '\nSelect an option [1-3]: '
    read -r choice

    case "${choice}" in
        1) printf '\n'; show_web_hint ;;
        2) printf '\n'; show_asg_hint ;;
        3) return ;;
        *) warning "Please enter a number from 1 to 3." ;;
    esac
}

verify_solution() {
    local asg_name policy_name alarm_name instance_id state public_ip url code body
    local min_size desired max_size in_service
    local policy_type adjustment_type scaling_adjustment policy_arn
    local alarm_enabled alarm_actions
    local website_result="FAIL" asg_result="FAIL" alarm_result="FAIL" policy_result="FAIL"

    printf '\nChecking your solution...\n\n'
    aws_session_ready || return
    require_command curl || return

    if ! stack_exists; then
        warning "No lab environment is currently deployed."
        return
    fi

    asg_name="$(stack_output AutoScalingGroupName)"
    policy_name="$(stack_output ScalingPolicyName)"
    alarm_name="$(stack_output HighCpuAlarmName)"
    instance_id="$(primary_asg_instance "${asg_name}")"
    public_ip="None"
    state="Not available"
    if [[ -n "${instance_id}" && "${instance_id}" != "None" ]]; then
        public_ip="$(instance_public_ip "${instance_id}")"
        state="$(instance_state "${instance_id}")"
    fi

    if [[ -n "${public_ip}" && "${public_ip}" != "None" ]]; then
        url="http://${public_ip}"
        body="$(curl --connect-timeout 5 --max-time 10 --silent --show-error "${url}" 2>/dev/null || true)"
        code="$(website_http_code "${url}")"
        if [[ "${state}" == "running" && "${code}" == "200" && "${body}" == *"AWS Foundation Troubleshooting Lab"* ]]; then
            website_result="PASS"
        fi
    fi

    read -r min_size desired max_size in_service <<< "$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "${asg_name}" \
        --query 'AutoScalingGroups[0].[MinSize,DesiredCapacity,MaxSize,length(Instances[?LifecycleState==`InService`])]' \
        --output text 2>/dev/null)"
    if [[ "${min_size:-}" == "1" && "${desired:-}" =~ ^[0-9]+$ && \
          "${max_size:-}" =~ ^[0-9]+$ && "${in_service:-}" =~ ^[0-9]+$ ]] && \
       (( desired >= 1 && max_size >= 2 && in_service >= 1 )); then
        asg_result="PASS"
    fi

    read -r policy_type adjustment_type scaling_adjustment policy_arn <<< "$(aws autoscaling describe-policies \
        --auto-scaling-group-name "${asg_name}" \
        --policy-names "${policy_name}" \
        --query 'ScalingPolicies[0].[PolicyType,AdjustmentType,ScalingAdjustment,PolicyARN]' \
        --output text 2>/dev/null)"
    if [[ "${policy_type:-}" == "SimpleScaling" && \
          "${adjustment_type:-}" == "ChangeInCapacity" && \
          "${scaling_adjustment:-}" == "1" ]]; then
        policy_result="PASS"
    fi

    read -r alarm_enabled alarm_actions <<< "$(aws cloudwatch describe-alarms \
        --alarm-names "${alarm_name}" \
        --query 'MetricAlarms[0].[ActionsEnabled,join(`,`,AlarmActions)]' \
        --output text 2>/dev/null)"
    if [[ "${alarm_enabled:-}" =~ ^([Tt]rue)$ && \
          -n "${policy_arn:-}" && \
          "${alarm_actions:-}" == *"${policy_arn}"* ]]; then
        alarm_result="PASS"
    fi

    printf "Website connectivity:  %s\n" "${website_result}"
    printf "Auto Scaling Group:    %s\n" "${asg_result}"
    printf "High CPU alarm:        %s\n" "${alarm_result}"
    printf "Scale-out policy:      %s\n\n" "${policy_result}"

    if [[ "${website_result}" == "PASS" && "${asg_result}" == "PASS" && \
          "${alarm_result}" == "PASS" && "${policy_result}" == "PASS" ]]; then
        success "RESULT: All troubleshooting tasks completed successfully!"
        printf "The website and Auto Scaling configuration have both been verified.\n"
    else
        warning "RESULT: Lab not completed yet."
        printf "Continue troubleshooting each area marked FAIL.\n"
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
        rm -f -- "${WEB_HINT_FILE}" "${ASG_HINT_FILE}" "${READY_FILE}"
        rmdir -- "${STATE_DIR}" 2>/dev/null || true
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
        rm -f -- "${WEB_HINT_FILE}" "${ASG_HINT_FILE}" "${READY_FILE}"
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
            1)
                if deploy_lab; then
                    printf '\nDeployment is complete, so this menu will now close.\n'
                    printf 'To check status, show the Web URL, get hints, verify, or delete the lab, run:\n\n'
                    printf '  cd %q\n' "${SCRIPT_DIR}"
                    printf '  bash run.sh\n\n'
                    exit 0
                fi
                pause
                ;;
            2) check_lab_status; pause ;;
            3) show_web_url; pause ;;
            4) show_hint_menu; pause ;;
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
