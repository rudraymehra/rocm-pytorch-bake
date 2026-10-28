#!/usr/bin/env bash
# Launch one benchmark host in us-east-2 with every cost guardrail on.
#
#   KEY_NAME=... SUBNET_ID=... SG_ID=... [MARKET=spot|on-demand] [MAX_HOURS=5] \
#       infra/ec2/launch.sh [instance-type] [data-gib]
#
# Spot and on-demand have separate vCPU quotas (L-34B43A08 and L-1216C47A); the
# instance must fit the quota of the chosen market. On an 8-vCPU quota use
# m7a.2xlarge with MAX_HOURS=12 (docs/OPERATIONS.md, "Small hosts").
#
# Guardrails: one-time spot (or on-demand), terminate on shutdown (stop would keep
# billing the volumes), volumes deleted on termination, IMDSv2 only, tags with an
# expiry time, and the dead-man switches in user-data.sh.
set -euo pipefail

: "${KEY_NAME:?}" "${SUBNET_ID:?}" "${SG_ID:?}"
type=${1:-m7a.16xlarge}
data_gib=${2:-1000}
market=${MARKET:-spot}
max_hours=${MAX_HOURS:-5}
[[ "$max_hours" =~ ^[1-9][0-9]?$ ]] || { echo "MAX_HOURS must be 1-99" >&2; exit 2; }
region=us-east-2
expires=$(date -u -d "+$max_hours hours" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -v+"$max_hours"H +%Y-%m-%dT%H:%MZ)
here=$(cd "$(dirname "$0")" && pwd)
case "$market" in
    spot) market_opts=(--instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}')
          spot_tags=("ResourceType=spot-instances-request,Tags=[TAGS]") ;;
    on-demand) market_opts=() spot_tags=() ;;
    *) echo "MARKET must be spot or on-demand" >&2; exit 2 ;;
esac
user_data=$(mktemp)
trap 'rm -f "$user_data"' EXIT
sed "s/^MAX_HOURS=5\$/MAX_HOURS=$max_hours/" "$here/user-data.sh" > "$user_data"
grep -q "^MAX_HOURS=$max_hours\$" "$user_data"

ami=$(aws ssm get-parameter --region "$region" \
    --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id \
    --query Parameter.Value --output text)

tags="{Key=project,Value=rocm-pytorch-bake},{Key=expires-at,Value=$expires}"
aws ec2 run-instances --region "$region" \
    --image-id "$ami" --instance-type "$type" \
    --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
    ${market_opts[@]+"${market_opts[@]}"} \
    --instance-initiated-shutdown-behavior terminate \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled \
    --block-device-mappings \
        "DeviceName=/dev/sda1,Ebs={VolumeSize=60,VolumeType=gp3,DeleteOnTermination=true}" \
        "DeviceName=/dev/sdf,Ebs={VolumeSize=$data_gib,VolumeType=gp3,Iops=16000,Throughput=1000,DeleteOnTermination=true}" \
    --tag-specifications "ResourceType=instance,Tags=[$tags]" "ResourceType=volume,Tags=[$tags]" \
        ${spot_tags[@]+"${spot_tags[@]/TAGS/$tags}"} \
    --user-data "file://$user_data" \
    --query 'Instances[0].InstanceId' --output text
