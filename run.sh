#!/bin/bash

# Create VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value="Troubleshooting VPC"
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}"

# Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

# Create Public Subnet
PUBLIC_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)

# Create Private Subnet
PRIVATE_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)

# Create a route table for the public subnet
PUBLIC_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)

# Associate the public route table with the public subnet
aws ec2 associate-route-table --route-table-id $PUBLIC_RT_ID --subnet-id $PUBLIC_SUBNET_ID >/dev/null 2>&1

# Create a route in the public route table that points all traffic (0.0.0.0/0) to the Internet Gateway
aws ec2 create-route --route-table-id $PUBLIC_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

# Create Security Group
SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name "SG-Troubleshoot" --description "Web security group" --vpc-id $VPC_ID --query 'GroupId' --output text)

# Add inbound rules to the security group
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 880 --cidr 0.0.0.0/0

# Choose AMI
AMI_ID="ami-09d3b3274b6c5d4aa"

# Instance Type
INSTANCE_TYPE="t2.micro"

# Create Key Pair
# aws ec2 create-key-pair --key-name my-key-pair --query 'KeyMaterial' --output text > my-key-pair.pem
# chmod 400 my-key-pair.pem

# Launch EC2 instance in the public subnet
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name vockey \
    --security-group-ids $SECURITY_GROUP_ID \
    --subnet-id $PUBLIC_SUBNET_ID \
    --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Troubleshooting-instance}]' \
    --user-data file://userdata.txt \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp2"}}]' \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance launched with id $INSTANCE_ID"

echo "*****************************************************"
echo "Please wait until it finish, it may take 2-5 mins"  **
echo "*****************************************************"
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID
aws ec2 delete-route --route-table-id $PUBLIC_RT_ID --destination-cidr-block 0.0.0.0/0
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "HTTP server installed and started on the instance with IP: $PUBLIC_IP"

# List all information
aws ec2 describe-instances \
 --filters "Name=instance-state-name,Values=running" \
 --region us-east-1 \
 --query 'Reservations[*].Instances[*].{AZ:Placement.AvailabilityZone,Name:Tags[?Key==`Name`] | [0].Value, ID:InstanceId, PrivateIp:PrivateIpAddress, PublicIp:PublicIpAddress}' \
 --output table
