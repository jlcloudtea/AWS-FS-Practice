# AWS Foundation Troubleshooting Lab

This guided practice lab creates an intentionally misconfigured AWS web-server environment. Your task is to restore public access to the website and correct its Auto Scaling policy.

## Troubleshooting scope

The exercise contains one issue in each of these areas:

- Public subnet network path
- EC2 web traffic access
- Auto Scaling high-CPU response

## Learning objectives

After completing the lab, you should be able to:

- Follow the network path from the internet to an EC2 instance.
- Inspect an EC2 instance, subnet, route table, Internet Gateway, and security group.
- Identify common causes of failed HTTP connectivity.
- Trace the relationship between an Auto Scaling Group, scaling policy, and CloudWatch alarm.
- Determine whether a scale-out policy increases or decreases capacity.
- Test and verify a repaired AWS environment.
- Safely delete AWS resources after a practical activity.

## Lab environment

The lab creates these resources in `us-east-1`:

- One VPC
- One public subnet and one private subnet
- One Internet Gateway
- One public route table
- One security group
- One EC2 Launch Template
- One Auto Scaling Group with an Amazon Linux web server
- One high-CPU CloudWatch alarm and dynamic scaling policy
- One EventBridge rule and Lambda function for automatic cleanup

The environment is managed by an AWS CloudFormation stack named `aws-foundation-troubleshooting-lab`.

## Requirements

- An active AWS Academy Learner Lab session
- AWS CloudShell or another Bash environment with AWS CLI and `curl`
- Permission to use EC2, VPC, EC2 Auto Scaling, CloudWatch, CloudFormation, Lambda, EventBridge, Systems Manager public parameters, STS, and the AWS Academy `LabRole`
- Region `us-east-1`

The activity normally takes 25–45 minutes. Deployment usually takes 4–10 minutes.

## Start the lab

In AWS CloudShell, run:

```bash
git clone https://github.com/jlcloudtea/AWS-FS-Practice.git
cd AWS-FS-Practice
bash run.sh
```

The menu will open:

```text
========================================
 AWS Foundation Troubleshooting Lab
========================================
 Region:     us-east-1
 Lab status: NOT DEPLOYED

1. Deploy Lab Environment
2. Check Lab Status
3. Show Web URL
4. Get Troubleshooting Hints
5. Verify My Solution
6. Delete Lab Environment
7. Exit
```

## Student workflow

1. Select **Deploy Lab Environment** and wait until deployment finishes.
2. Select **Show Web URL** and test the address in a new browser tab.
3. Use the AWS console to inspect the environment and identify why the website is unavailable.
4. Make the minimum configuration changes needed to restore access.
5. Inspect the high-CPU alarm and its attached Auto Scaling policy.
6. Correct the policy so that a high-CPU event would add one instance.
7. Select **Verify My Solution**.
8. When finished, select **Delete Lab Environment** and type `DELETE` to confirm.

Use **Get Troubleshooting Hints** if you become stuck. Web connectivity and Auto Scaling have separate sets of three progressive hints.

## Success criteria

The lab is complete when **Verify My Solution** reports:

```text
RESULT: All troubleshooting tasks completed successfully!
```

The verifier checks website connectivity, the Auto Scaling Group limits, the high-CPU alarm connection, and the scaling policy action. It does not trigger scaling or modify your solution.

## Important cleanup requirement

The stack schedules automatic deletion four hours after deployment as a safety net. The timer continues even if CloudShell is closed and is not extended by activity in the lab.

Do not wait for the timer during normal use. Always use menu option 6 when the activity is complete so resources are removed immediately. Exiting the menu does not delete AWS resources.

If normal deletion fails, open CloudFormation in `us-east-1`, inspect the stack events, and retry deletion. Ask your lecturer before manually deleting individual stack resources.

## Common setup problems

### AWS credentials are not active

Start or restart the AWS Academy Learner Lab, wait for the AWS indicator to turn green, and open CloudShell again.

### A lab already exists

Use menu option 2 to inspect it. If you want a fresh attempt, delete the existing lab with option 6 before deploying again.

### Deployment failed

Open CloudFormation in `us-east-1`, select `aws-foundation-troubleshooting-lab`, and inspect the **Events** tab. Delete a failed stack before trying again.

If the failed resource is the automatic cleanup function, confirm that the AWS Academy account provides a Lambda-compatible role named `LabRole`. Lecturers using a different environment can set `CLEANUP_ROLE_ARN` to a suitable existing role ARN before running the script.

### The web server setup timed out

Wait two minutes, delete the environment, and deploy again. The script does not apply the two network faults when server setup cannot be confirmed.

## Lecturer information

Implementation details, expected faults, validation steps, and reset guidance are in [docs/LECTURER_GUIDE.md](docs/LECTURER_GUIDE.md).
