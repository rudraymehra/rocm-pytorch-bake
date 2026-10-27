#!/usr/bin/env bash
# Launch one spot benchmark host in us-east-2 with every cost guardrail on.
#
#   KEY_NAME=... SUBNET_ID=... SG_ID=... infra/ec2/launch.sh [instance-type] [data-gib]
#
# Guardrails: one-time spot, terminate on shutdown (stop would keep billing the
# volumes), volumes deleted on termination, IMDSv2 only, tags with an expiry time,
# and the dead-man switches in user-data.sh.
set -euo pipefail

: "${KEY_NAME:?}" "${SUBNET_ID:?}" "${SG_ID:?}"
type=${1:-m7a.16xlarge}
data_gib=${2:-1000}
region=us-east-2
expires=$(date -u -d '+5 hours' +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -v+5H +%Y-%m-%dT%H:%MZ)
here=$(cd "$(dirname "$0")" && pwd)

ami=$(aws ssm get-parameter --region "$region" \
    --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id \
    --query Parameter.Value --output text)

tags="{Key=project,Value=rocm-pytorch-bake},{Key=expires-at,Value=$expires}"
aws ec2 run-instances --region "$region" \
    --image-id "$ami" --instance-type "$type" \
    --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
    --instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}' \
    --instance-initiated-shutdown-behavior terminate \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled \
    --block-device-mappings \
        "DeviceName=/dev/sda1,Ebs={VolumeSize=60,VolumeType=gp3,DeleteOnTermination=true}" \
        "DeviceName=/dev/sdf,Ebs={VolumeSize=$data_gib,VolumeType=gp3,Iops=16000,Throughput=1000,DeleteOnTermination=true}" \
    --tag-specifications "ResourceType=instance,Tags=[$tags]" "ResourceType=volume,Tags=[$tags]" \
        "ResourceType=spot-instances-request,Tags=[$tags]" \
    --user-data "file://$here/user-data.sh" \
    --query 'Instances[0].InstanceId' --output text
