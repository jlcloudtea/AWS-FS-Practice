# Lecturer Guide

> This guide contains the solution. Do not direct students to it until they have completed the activity.

## Intended scope

This version focuses on EC2 web connectivity through a public subnet. It does not currently assess Auto Scaling troubleshooting.

## Seeded faults

After confirming that the website is working, the menu controller intentionally creates two faults:

1. The EC2 security group allows inbound TCP port `880`, but Apache listens on TCP port `80`.
2. After the instance bootstrap completes, `lab.sh` removes the public route table's `0.0.0.0/0` route to the Internet Gateway.

TCP port 80 and the default route are initially present so that the instance can install Apache. The script successfully requests the expected webpage before replacing TCP port 80 with port 880 and removing the route. This avoids relying only on EC2 status checks or console-output access.

## Expected student solution

Students should:

1. Add or correct the security-group inbound rule to allow HTTP TCP port 80 from `0.0.0.0/0`.
2. Add `0.0.0.0/0` to the public route table with the lab Internet Gateway as the target.
3. Run menu option 5 to verify the website.

SSH is intentionally not enabled or required.

## Suggested observation points

Ask students to explain, rather than only demonstrate, the following:

- Why an instance can be in the `running` state while its website remains unreachable.
- Why a public IPv4 address alone does not provide internet connectivity.
- How the subnet association identifies the effective route table.
- Why the security-group port must match the application listening port.
- Why both the route and the security-group correction are necessary.

## Verification behavior

The verifier is deliberately non-diagnostic. It confirms:

- The stack exists.
- The EC2 instance is running.
- A public IPv4 address is assigned.
- The URL returns HTTP 200.
- The response contains `AWS Foundation Troubleshooting Lab`.

On failure it does not identify which seeded fault remains.

## Repeat testing checklist

Test the feature branch in a fresh AWS Academy Learner Lab account:

1. Deploy successfully in `us-east-1`.
2. Confirm a second deployment is blocked.
3. Confirm the initial web request fails.
4. Confirm hints appear in order.
5. Correct only one fault and confirm verification still fails.
6. Correct both faults and confirm verification passes.
7. Delete the stack from the menu.
8. Confirm the VPC, instance, security group, route table, subnets, and Internet Gateway are removed.
9. Deploy and delete once more to validate repeatability.

## Recovery from failed deletion

CloudFormation remains the resource owner even though the activity introduces stack drift. If deletion fails:

1. Inspect the first `DELETE_FAILED` event.
2. Remove only the dependency named in that event.
3. Retry deleting the stack.

Avoid asking students to delete the VPC first because dependent resources will prevent it.
