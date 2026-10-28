#!/usr/bin/env bash
# Prove that nothing billable from this project is left in ANY region.
# Prints every leftover resource and exits 1 if there is one; prints "clean" and
# exits 0 otherwise. Exits 2 if any AWS call fails (expired credentials, missing
# permission, throttling): an unanswered question is never reported as "clean".
#
# It finds resources tagged project=rocm-pytorch-bake, which infra/ec2/launch.sh
# puts on the instance, its volumes and its spot request. Resources made by hand
# without that tag (an AMI, a snapshot, an Elastic IP) are not found.
set -euo pipefail

filter=Name=tag:project,Values=rocm-pytorch-bake
left=0

aws_q() { # aws_q <aws args...>: print the output, or stop with exit 2 on any failure
    local out
    if ! out=$(aws "$@" 2>&1); then
        echo "teardown-check: 'aws $*' failed: $out" >&2
        echo "teardown-check: could not verify; NOT clean" >&2
        exit 2
    fi
    printf '%s' "$out"
}

report() { # report <region> <kind> <ids>
    if [ -n "$3" ] && [ "$3" != "None" ]; then
        printf '%s\t%s\t%s\n' "$1" "$2" "$3"
        left=1
    fi
}

regions=$(aws_q ec2 describe-regions --query 'Regions[].RegionName' --output text)
[ -n "$regions" ] || { echo "teardown-check: no regions returned; NOT clean" >&2; exit 2; }

for r in $regions; do
    ids=$(aws_q ec2 describe-instances --region "$r" --filters "$filter" \
        Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped \
        --query 'Reservations[].Instances[].InstanceId' --output text)
    report "$r" instance "$ids"
    ids=$(aws_q ec2 describe-volumes --region "$r" --filters "$filter" \
        --query 'Volumes[].VolumeId' --output text)
    report "$r" volume "$ids"
    ids=$(aws_q ec2 describe-spot-instance-requests --region "$r" \
        --filters "$filter" Name=state,Values=open,active \
        --query 'SpotInstanceRequests[].SpotInstanceRequestId' --output text)
    report "$r" spot-request "$ids"
    ids=$(aws_q ec2 describe-addresses --region "$r" --filters "$filter" \
        --query 'Addresses[].AllocationId' --output text)
    report "$r" elastic-ip "$ids"
    ids=$(aws_q ec2 describe-snapshots --region "$r" --owner-ids self --filters "$filter" \
        --query 'Snapshots[].SnapshotId' --output text)
    report "$r" snapshot "$ids"
    ids=$(aws_q ec2 describe-images --region "$r" --owners self --filters "$filter" \
        --query 'Images[].ImageId' --output text)
    report "$r" image "$ids"
done

if [ "$left" -eq 0 ]; then
    echo clean
fi
exit "$left"
