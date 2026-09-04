# Lecturer Guide

> This guide contains the solution. Do not direct students to it until they have completed the activity.

## Intended scope

This version covers EC2 web connectivity through a public subnet and a simple Auto Scaling policy connected to a high-CPU CloudWatch alarm.

## Seeded faults

The lab contains three intentional faults:

1. The EC2 security group allows inbound TCP port `880`, but Apache listens on TCP port `80`.
2. After the instance bootstrap completes, `lab.sh` removes the public route table's `0.0.0.0/0` route to the Internet Gateway.
3. The high-CPU policy uses `ChangeInCapacity` with a scaling adjustment of `-1`, so it attempts to remove capacity instead of adding one instance.

TCP port 80 and the default route are initially present so that the instance can install Apache. The script successfully requests the expected webpage before replacing TCP port 80 with port 880 and removing the route. This avoids relying only on EC2 status checks or console-output access.

## Expected student solution

Students should:

1. Add or correct the security-group inbound rule to allow HTTP TCP port 80 from `0.0.0.0/0`.
2. Add `0.0.0.0/0` to the public route table with the lab Internet Gateway as the target.
3. Edit the high-CPU dynamic scaling policy and change the capacity action from removing one instance to adding one instance (`ScalingAdjustment: 1`).
4. Run menu option 5 to verify all three corrections.

SSH is intentionally not enabled or required.

## Suggested observation points

Ask students to explain, rather than only demonstrate, the following:

- Why an instance can be in the `running` state while its website remains unreachable.
- Why a public IPv4 address alone does not provide internet connectivity.
- How the subnet association identifies the effective route table.
- Why the security-group port must match the application listening port.
- Why both the route and the security-group correction are necessary.
- How the CloudWatch alarm identifies the Auto Scaling Group metric.
- How the alarm action connects to the dynamic scaling policy.
- Why `-1` means removing capacity and `1` means adding capacity when using `ChangeInCapacity`.

## Verification behavior

The verifier is deliberately non-diagnostic. It confirms:

- The stack exists.
- An Auto Scaling instance is running with a public IPv4 address.
- The expected webpage returns HTTP 200.
- The Auto Scaling Group has minimum 1, desired at least 1, maximum at least 2, and at least one InService instance.
- The high-CPU alarm is enabled and connected to the intended scaling policy.
- The policy is `SimpleScaling`, uses `ChangeInCapacity`, and adds exactly one instance.

On failure it identifies the affected area, such as website connectivity or the scale-out policy, but it does not expose the incorrect value or provide the exact correction.

## Repeat testing checklist

Test the feature branch in a fresh AWS Academy Learner Lab account:

1. Deploy successfully in `us-east-1`.
2. Confirm a second deployment is blocked.
3. Confirm the initial web request fails.
4. Confirm both categories of hints appear in order.
5. Correct the two connectivity faults and confirm the website check passes while the policy check fails.
6. Correct the scaling adjustment and confirm all verification checks pass.
7. Confirm the ASG still has one InService instance; verification must not execute the policy.
8. Delete the stack from the menu.
9. Confirm the VPC, ASG instances, Launch Template, scaling policy, alarm, security group, route table, subnets, and Internet Gateway are removed.
10. Deploy and delete once more to validate repeatability.

## Recovery from failed deletion

CloudFormation remains the resource owner even though the activity introduces stack drift. If deletion fails:

1. Inspect the first `DELETE_FAILED` event.
2. Remove only the dependency named in that event.
3. Retry deleting the stack.

Avoid asking students to delete the VPC first because dependent resources will prevent it.
