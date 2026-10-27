#!/usr/bin/env bash
# Prove that nothing billable from this project is left in ANY region.
# Prints every leftover resource and exits 1 if there is one; prints "clean" and exits 0 otherwise.
set -euo pipefail

filter=Name=tag:project,Values=rocm-pytorch-bake
left=0

report() { # report <region> <kind> <lines...>
    local region=$1 kind=$2 lines=$3
    if [ -n "$lines" ]; then
        printf '%s\t%s\t%s\n' "$region" "$kind" "$lines"
        left=1
    fi
}

for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
    report "$r" instance "$(aws ec2 describe-instances --region "$r" --filters "$filter" \
        Name=instance-state-name,Values=pending,running,stopping,stopped \
        --query 'Reservations[].Instances[].InstanceId' --output text)"
    report "$r" volume "$(aws ec2 describe-volumes --region "$r" --filters "$filter" \
        --query 'Volumes[].VolumeId' --output text)"
    report "$r" spot-request "$(aws ec2 describe-spot-instance-requests --region "$r" \
        --filters "$filter" Name=state,Values=open,active \
        --query 'SpotInstanceRequests[].SpotInstanceRequestId' --output text)"
    report "$r" elastic-ip "$(aws ec2 describe-addresses --region "$r" --filters "$filter" \
        --query 'Addresses[].AllocationId' --output text)"
    report "$r" snapshot "$(aws ec2 describe-snapshots --region "$r" --owner-ids self --filters "$filter" \
        --query 'Snapshots[].SnapshotId' --output text)"
done

if [ "$left" -eq 0 ]; then
    echo clean
fi
exit "$left"
