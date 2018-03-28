#!/bin/bash
# Date: 2015-10-26
# Version 0.10
# License Type: GNU GENERAL PUBLIC LICENSE, Version 3
# Author:
# Colin Johnson / https://github.com/colinbjohnson / colin@cloudavail.com
# Contributors:
# Alex Corley / https://github.com/anthroprose
# Jon Higgs / https://github.com/jonhiggs
# Mike / https://github.com/eyesis
# Jeff Vogt / https://github.com/jvogt
# Dave Stern / https://github.com/davestern
# Josef / https://github.com/J0s3f
# buckelij / https://github.com/buckelij
# https://github.com/ccomerImmerge

set -e

print_error() {
  >&2 echo -e "$@"
}

fail() {
  local code=${2:-1}
  [[ -n $1 ]] && print_error "$1"
  # shellcheck disable=SC2086
  exit $code
}

has_cmd() {
  local command=${1?command is required}
  command -v "$command" > /dev/null 2>&1
}

# http://stackoverflow.com/questions/1527049/join-elements-of-an-array#17841619
join() {
  local IFS=${1?separator is required}
  shift

  echo -n "$*"
}

# confirms that executables required for succesful script execution are
# available
prerequisite_check() {
  for cmd in basename cut date aws; do
    if ! has_cmd $cmd; then
      fail "$(cat <<-EOF
        In order to use ${APP_NAME}, the executable "${cmd}" must be installed.
				EOF
      )" 70
    fi
  done
}

run() {
  if [[ $DEBUG == true ]]; then
    (set -x; "$@")
  else
    "$@"
  fi
}

# get_ebs_list gets a list of available EBS instances depending upon the
# SELECTION_METHOD of EBS selection that is provided by user input
get_ebs_list() {
  case $SELECTION_METHOD in
    volume-id)
      if [[ -z $VOLUME_ID ]]; then
        fail "$(cat <<-EOF
					The selection method "volume-id" (which is ${APP_NAME}'s default
					SELECTION_METHOD of operation or requested by using the -s volume-id
					parameter) requires a volume-id (-v volume-id) for operation. Correct
					usage is as follows: "-v vol-6d6a0527","-s volume-id -v vol-6d6a0527"
					or "-v "vol-6d6a0527 vol-636a0112" if multiple volumes are to be
					selected.
					EOF
        )" 64
      fi
      local ebs_selection_string="--volume-ids ${VOLUME_ID}"
      ;;
    tag)
      if [[ -z $TAG ]]; then
        fail "$(cat <<-EOF
					The selected SELECTION_METHOD "tag" (-s tag) requires a valid tag (-t
					Backup,Values=true) for operation. Correct usage is as follows: "-s
					tag -t Backup,Values=true."
					EOF
        )" 64
      fi
      local ebs_selection_string="--filters Name=tag:${TAG}"
      ;;
    *)
      fail "$(cat <<-EOF
				If you specify a SELECTION_METHOD (-s SELECTION_METHOD) for selecting
				EBS volumes you must select either "volume-id" (-s volume-id) or "tag"
				(-s tag).
				EOF
      )" 64
      ;;
  esac

  # creates a list of all ebs volumes that match the selection string from
  # above
  # shellcheck disable=SC2086
  if ! EBS_BACKUP_LIST=$(
    run aws ec2 describe-volumes \
      --region "$REGION" \
      $ebs_selection_string \
      --output text \
      --query 'Volumes[*].VolumeId'
  ); then
    fail "$(cat <<-EOF
			An error occurred when running ec2-describe-volumes. The error returned
			is below:
			$EBS_BACKUP_LIST
			EOF
    )" 70
  fi
}

# construct an ec2 "tag specification".
# per aws ec2 create-snapshot help
#
# ResourceType=string,Tags=[{Key=string,Value=string},{Key=string,Value=string}]
snapshot_tags() {
  local vol_id=${1?vol_id is required}

  declare -A tags
  tags[CreatedBy]="ec2-automate-backup"

  if [[ $NAME_TAG_CREATE == true && -v vol_id && -v CURRENT_DATE ]]; then
    tags[Name]="ec2ab_${vol_id}_${CURRENT_DATE}"
  fi

  if [[ $HOSTNAME_TAG_CREATE == true ]]; then
    tags[InitiatingHost]="$(hostname -s)"
  fi

  if [[ -v PURGE_AFTER_DATE_FE ]]; then
    tags[PurgeAfterFE]="${PURGE_AFTER_DATE_FE}"
    tags[PurgeAllow]="true"
  fi

  if [[ $USER_TAGS == true ]]; then
    [[ -v vol_id ]] && tags[Volume]="${vol_id}"
    [[ -v CURRENT_DATE ]] && tags[Created]="$CURRENT_DATE"
  fi

  local pairs=()
  for k in "${!tags[@]}"
  do
    pairs+=("{Key=${k},Value=${tags[$k]}}")
  done

  if [[ -v CUSTOM_TAGS ]]; then
    for item in $CUSTOM_TAGS; do
      pairs+=("{${item}}")
    done
  fi

  local tagsSpec
  tagsSpec="ResourceType=snapshot,Tags=[$(join ',' "${pairs[@]}")]"

  echo "$tagsSpec"
}

get_date_binary() {
  # $(uname -o) (operating system) would be ideal, but OS X / Darwin does not
  # support to -o option
  # $(uname) on OS X defaults to $(uname -s) and $(uname) on GNU/Linux defaults
  # to $(uname -s)
  local uname_result
  uname_result=$(uname)
  case $uname_result in
    Darwin|FreeBSD)
      echo 'posix';;
    Linux)
      echo 'linux-gnu';;
    *)
      echo 'unknown';;
  esac
}

get_purge_after_date_fe() {
  local purge_after_value_seconds

  case $PURGE_AFTER_INPUT in
    # numbers followed by a letter "d" or "days"
    [0-9]*d)
      purge_after_value_seconds=$(( ${PURGE_AFTER_INPUT%?} * 86400 ))
      ;;
    # numbers followed by a letter "h" or "hours"
    [0-9]*h)
      purge_after_value_seconds=$(( ${PURGE_AFTER_INPUT%?} * 3600 ))
      ;;
    # numbers followed by a letter "m" or "minutes"
    [0-9]*m)
      purge_after_value_seconds=$(( ${PURGE_AFTER_INPUT%?} * 60 ))
      ;;
    # numbers followed by a letter "s" or "seconds"
    [0-9]*s)
      purge_after_value_seconds=$(( ${PURGE_AFTER_INPUT%?} ))
      ;;
    # no trailing letter defaults to days
    *)
      purge_after_value_seconds=$(( PURGE_AFTER_INPUT * 86400 ))
      ;;
  esac

  # convert seconds into the future into a unix epoch
  case $DATE_BINARY in
    linux-gnu)
      date -d +${purge_after_value_seconds}sec -u +%s;;
    posix)
      date -v +${purge_after_value_seconds}S -u +%s;;
    *)
      date -d +${purge_after_value_seconds}sec -u +%s;;
  esac
}

purge_ebs_snapshots() {
  local filters=("Name=tag:PurgeAllow,Values=true")

  if [[ -v CUSTOM_TAGS ]]; then
    local fixed_keys="${CUSTOM_TAGS//Key=/Name=tag:}"
    filters+=("${fixed_keys//Value=/Values=}")
  fi

  # snapshot_purge_allowed is a string containing the SnapshotIDs of snapshots
  # that contain a tag with the key value/pair PurgeAllow=true
  local snapshot_purge_allowed
  snapshot_purge_allowed=$(
    run aws ec2 describe-snapshots \
      --region "$REGION" \
      --filters "${filters[@]}" \
      --output text \
      --query 'Snapshots[*].SnapshotId'
  )

  for snapshot_id_evaluated in $snapshot_purge_allowed; do
    # gets the "PurgeAfterFE" date which is in UTC with UNIX Time format (or
    # xxxxxxxxxx / %s)
    local purge_after_fe
    # shellcheck disable=SC2016
    purge_after_fe=$(
      run aws ec2 describe-snapshots \
        --region "$REGION" \
        --snapshot-ids "$snapshot_id_evaluated" \
        --output text \
        --query 'Snapshots[*].Tags[?Key==`PurgeAfterFE`].Value'
    )

    # if purge_after_date is not set then we have a problem. Need to alert
    # user.
    if [[ -z $purge_after_fe ]]; then
      # Alerts user to the fact that a Snapshot was found with PurgeAllow=true
      # but with no PurgeAfterFE date.
      print_error "$(cat <<-EOF
				Snapshot with the Snapshot ID "${snapshot_id_evaluated}" has the tag
				"PurgeAllow=true" but does not have a "PurgeAfterFE=xxxxxxxxxx"
				key/value pair.  ${APP_NAME} is unable to determine if
				${snapshot_id_evaluated} should be purged."
				EOF
			)"
    else
      # if $purge_after_fe is less than $CURRENT_DATE then
      # PurgeAfterFE is earlier than the current date
      # and the snapshot can be safely purged
      if [[ $purge_after_fe < $CURRENT_DATE ]]; then
        print_error "$(cat <<-EOF
					Snapshot "${snapshot_id_evaluated}" with the PurgeAfterFE date of
					"${purge_after_fe}" will be deleted."
					EOF
        )"
        run aws ec2 delete-snapshot \
          --region "$REGION" \
          --snapshot-id "$snapshot_id_evaluated" \
          --output text
      fi
    fi
  done
}

# calls prerequisitecheck function to ensure that all executables required for
# script execution are available
prerequisite_check

APP_NAME="$(basename "$0")"
# sets defaults
SELECTION_METHOD="volume-id"
# DATE_BINARY allows a user to set the "date" binary that is installed on their
# system and, therefore, the options that will be given to the date binary to
# perform date calculations
DATE_BINARY=${DATE_BINARY:-$(get_date_binary)}
# sets the "Name" tag set for a snapshot to false - using "Name" requires that
# ec2-create-tags be called in addition to ec2-create-snapshot
NAME_TAG_CREATE=false
# sets the "InitiatingHost" tag set for a snapshot to false
HOSTNAME_TAG_CREATE=false
# sets the USER_TAGS feature to false - user_tag creates tags on snapshots - by
# default each snapshot is tagged with volume_id and CURRENT_DATE timestamp
USER_TAGS=false
# sets the Purge Snapshot feature to false - if PURGE_SNAPSHOTS=true then
# snapshots will be purged
PURGE_SNAPSHOTS=false
# default aws region
REGION=${AWS_DEFAULT_REGION:-us-east-1}

while getopts :s:c:r:v:t:k:c:pnhud opt; do
  case $opt in
    s) SELECTION_METHOD="$OPTARG" ;;
    r) REGION="$OPTARG" ;;
    v) VOLUME_ID="$OPTARG" ;;
    t) TAG="$OPTARG" ;;
    k) PURGE_AFTER_INPUT="$OPTARG" ;;
    n) NAME_TAG_CREATE=true ;;
    h) HOSTNAME_TAG_CREATE=true ;;
    p) PURGE_SNAPSHOTS=true ;;
    u) USER_TAGS=true ;;
    c) CUSTOM_TAGS="$OPTARG" ;;
    d) DEBUG=true ;;
    *)
      fail "$(cat <<-EOF
				Error with Options Input. Cause of failure is most likely that an
				unsupported parameter was passed or a parameter was passed without a
				corresponding option.
				EOF
      )" 64
      ;;
  esac
done

# sets date variable
CURRENT_DATE=$(date -u +%s)

# sets the PurgeAfterFE tag to the number of seconds that a snapshot should be
# retained
if [[ -n $PURGE_AFTER_INPUT ]]; then
  PURGE_AFTER_DATE_FE=$(get_purge_after_date_fe)
  cat <<-EOF
		Snapshots taken by $APP_NAME will be eligible for purging after the
		following date (the purge after date given in seconds from epoch):
		$PURGE_AFTER_DATE_FE.
		EOF
fi

# get_ebs_list gets a list of EBS instances for which a snapshot is desired.
# The list of EBS instances depends upon the SELECTION_METHOD that is provided
# by user input
get_ebs_list

# the loop below is called once for each volume in $EBS_BACKUP_LIST - the
# currently selected EBS volume is passed in as "ebs_selected"
for vol_id in $EBS_BACKUP_LIST; do
  ec2_snapshot_description="ec2ab_${vol_id}_$CURRENT_DATE"
  tag_spec="$(snapshot_tags "$vol_id")"

  if ! EC2_SNAPSHOT_RESOURCE_ID=$(
    run aws ec2 create-snapshot \
      --region "$REGION" \
      --description "$ec2_snapshot_description" \
      --volume-id "$vol_id" \
      --tag-specifications "$tag_spec" \
      --output text \
      --query SnapshotId
  ); then
    fail "$(cat <<-EOF
			An error occurred when running ec2-create-snapshot:
			$EC2_SNAPSHOT_RESOURCE_ID
			EOF
    )" 70
  fi
done

# if PURGE_SNAPSHOTS is true, then run purge_ebs_snapshots function
if $PURGE_SNAPSHOTS; then
  echo "Snapshot Purging is Starting Now."
  purge_ebs_snapshots
fi

# vim: tabstop=2 shiftwidth=2 expandtab
