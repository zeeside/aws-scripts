#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
new_ecs_count=0
new_asg_min_size=0
new_asg_max_size=0
new_asg_desired_capacity=0
warn_no_asg_adjustment=false
report_only=false
main_header="Current Values:"
updates_header="New Values:"
raw_delta=''

usage() {
  cat << EOF # remove the space between << and EOF, this is due to web plugin issue
Usage: $(basename "${BASH_SOURCE[0]}") [-h] --up|--down -a asg_value -c cluster_value -s service_value -d delta_value [--dry-run] 

This script requires authentication with AWS via the "Saml2aws login" command. The script 
can be used to scale any ecs service up or down. It can also be used to report capacity 
without executing any updates when the --dry-run flag is used. Note that an associated 
EC2 auto-scaling group must be provided. If the current ASG capacity is more than the desired 
scale-up capacity, the MinSize, MaxSize and DesiredCapacity will be left as is.  
Updates to the ASG will only occur if the computed scale-up value is greater than the current value

Available options:

-h, --help        Print this help and exit
-a, --asg         The autoscaling group for the EC2 cluster
--up              Scales up resources If you enter both --up and --down, the latter flag is used
--down            Scales down resources. If you enter both --up and --down, the latter flag is used
--dry-run         Reporting mode. Does not execute updates
-c, --cluster     The ECS service cluster
-d, --delta       The amount to increase ECS tasks by eg. 20 or 25%. Negative values or decimals are not supported.
-s, --service     The ECS service name
EOF
  exit
}

# compute the new number of ecs tasks to add
# either by percentage or absolute value
set_new_ecs_count() {
 local curr_count=$1
 change_amount=0

 if [ "$is_pct" = true  ] ; then
    # special case for ecs services with 0 tasks running
    # in this case set change_amount to 1
    if [ "$curr_count" = 0 ]; then
      change_amount=1
    else
      local div=$(echo $(( $curr_count*$delta/100 )))
      change_amount=$(echo $div | awk '{print int($1+0.5)}')
    fi
 else
    change_amount=$delta
 fi
 
 #increase or decirease ecs tasks
 if [ "$up" = true ] ; then
    new_ecs_count=$(($curr_count + $change_amount))
 else
    new_ecs_count=$(($curr_count - $change_amount))
 fi

 #no negative values
 if [ "${new_ecs_count}" -lt 0 ] ; then
    new_ecs_count=0
 fi
}

#figure out if the delta is 
#an absolute value or a percentage
resolve_delta() {
  local re_num='^[0-9]+$'
  raw_delta=$1
  local delta_value=$1

  if [[ "${delta_value}" == *"%"* ]]; then
    is_pct=true
    delta_value=$(echo ${delta_value//%})
  else
    is_pct=false
  fi

  if ! [[ $delta_value =~ $re_num ]] ; then
    die "The delta value you provided was not numeric. Valid Examples are 24 or 25%"
  else
    delta=$delta_value
  fi
}

#resolve how much to increase the
#ec2 asg capacity by
set_new_asg_count() {
 local curr_tasks_count=$1
 local curr_min_size=$2
 local curr_max_size=$3
 local curr_desired_capacity=$4
 new_asg_min_size=$curr_min_size
 new_asg_max_size=$curr_max_size
 new_asg_desired_capacity=$curr_desired_capacity

 # if in dry-run mode, update will not run, so add 
 # the delta to total running ecs tasks to get what the 
 # scaled value would have been
 if [ "${report_only}" = true ] && ! [ "${is_pct}" = true ]; then
    if [ "$up" = true ]; then
      curr_tasks_count=$(($curr_tasks_count + $delta))
    else
      curr_tasks_count=$(($curr_tasks_count - $delta))
    fi
 elif [ "${report_only}" = true ] && [ "${is_pct}" = true ]; then
    if [ "${curr_tasks_count}" = 0 ]; then
      curr_tasks_count=1
    else
      if [ "$up" = true ]; then
        curr_tasks_count=$(($change_amount + $curr_tasks_count))
      else
        curr_tasks_count=$(($curr_tasks_count - $change_amount))
      fi
    fi
 fi

 #bash doesn't support decimals, so curr_tasks_count / 2 will resolve to 
 #zero if it's 1
 if [ "$curr_tasks_count" = 1 ]; then
   desired_count=1
 else
   desired_count=$(( $curr_tasks_count / 2 ))
 fi
 
 
  #increase min_size if desired_count is greater than current minsize
  #prep "no-adjustment" message otherwise
  if [ "$up" = true ]; then
    if [ "$desired_count" -gt "$curr_min_size"  ];  then
        new_asg_min_size=$desired_count
    else
        warn_no_asg_adjustment=true
        new_asg_min_size=$curr_min_size
    fi

    if [ "$desired_count" -gt "$curr_max_size"  ];  then
        new_asg_max_size=$desired_count
    fi

    if [ "$desired_count" -gt "$curr_desired_capacity"  ];  then
        new_asg_desired_capacity=$desired_count
    fi
  else
    if [ "$desired_count" -lt "$curr_min_size"  ];  then
        new_asg_min_size=$desired_count
    else
        warn_no_asg_adjustment=true
        new_asg_min_size=$curr_min_size
    fi

    if [ "$desired_count" -lt "$curr_max_size"  ] ;  then
        new_asg_max_size=$desired_count
    fi

    if [ "$desired_count" -lt "$curr_desired_capacity"  ] ;  then
        new_asg_desired_capacity=$desired_count
    fi
  fi
}

count_substrings() {
  s=$1
  count=0
  SUB_STRING=$2
  until
    t=${s#*"$SUB_STRING"}
    [ "$t" = "$s" ]
  do
    count=$((count + 1))
    s=$t
  done
  echo $count
}


parse_params() {
  # default values of variables set from params
  flag=0
  asg=''
  cluster=''
  service=''

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;; 
    --up) up=true ;; 
    --down) up=false ;; 
    --dry-run) report_only=true ;; 
    -a | --asg) 
      asg="${2-}"
      shift
      ;;
    -c | --cluster) 
      cluster="${2-}"
      shift
      ;;
    -s | --service) 
      service="${2-}"
      shift
      ;;
    -d | --delta) 
      resolve_delta "${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${up-}" ]] && die "Missing --down or --up flag. We don't know which way to scale"
  [[ -z "${delta-}" ]] && die "Missing --delta flag. We don't know how much to scale by"
  [[ -z "${asg-}" ]] && die "Missing required parameter: --asg (EC2 Autoscaling group)"
  [[ -z "${service-}" ]] && die "Missing required parameter: --service"
  [[ -z "${cluster-}" ]] && die "Missing required parameter: --cluster"
  #[[ ${#args[@]} -eq 0 ]] && die "Missing script arguments"

  return 0
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
}

msg() {
  echo >&2 "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params "$@"

# Write dry run header if applicable
if [ "${report_only}" = true ]; then
  echo "*******************************************"
  echo "*       EXECUTING IN DRY RUN MODE         "
  echo "*******************************************"
  echo ""
  updates_header="New Values - (Updates not executed)"
fi

# get number of running tasks for the ecs service
echo "- checking number of running ecs tasks..."
current_ecs_tasks=$(aws ecs list-tasks --cluster ${cluster} --service-name ${service})
current_ecs_count=$(count_substrings "$current_ecs_tasks" "arn:aws:ecs:us-east-1")
set_new_ecs_count $current_ecs_count

# increase ecs service running tasks
if ! [ "${report_only}" = true ]; then
  echo "- updating desired-count for ecs task..."
  ecs_output=$(aws ecs update-service --service ${service} --cluster ${cluster}  --desired-count ${new_ecs_count})
fi

# get total running tasks in cluster
echo "- checking total number of running tasks in ecs cluster..."
total_running_task_count_raw=$(aws ecs list-tasks --cluster ${cluster})
total_running_task_count=$(count_substrings "$total_running_task_count_raw" "arn:aws:ecs:us-east-1")

# check MinSize, MaxSize and DesiredCapacity for EC2 auto scaling groups
echo "- validating autoscaling group..."
curr_asg_size_raw=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name ${asg})
min_size_count=$(count_substrings "$curr_asg_size_raw" "MinSize")

if [ "$min_size_count" = 0 ]; then
  echo "Autoscaling group ${asg} is either invalid or inactive. Stopping script."
  exit
fi

echo "- fetching MinSize, MaxSize and DesiredCapacity for autoscaling group..."
curr_asg_min_size=$(echo "${curr_asg_size_raw}" | grep MinSize  | tr -dc '0-9')
curr_asg_max_size=$(echo "${curr_asg_size_raw}" | grep MaxSize  | tr -dc '0-9')
curr_asg_desired_capacity=$(echo "${curr_asg_size_raw}" | grep DesiredCapacity  | tr -dc '0-9')
set_new_asg_count $total_running_task_count $curr_asg_min_size $curr_asg_max_size $curr_asg_desired_capacity


# update MinSize, MaxSize and DesiredCapacity
if ! [ "${report_only}" = true ]; then
echo "- scaling autoscaling group..."
aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name ${asg} \
    --min-size ${new_asg_min_size} \
    --max-size ${new_asg_max_size} \
    --desired-capacity ${new_asg_desired_capacity}
fi


if [ "${up}" = true ]; then
  requested_op="Desired ECS task increase: ${raw_delta}"
else
  requested_op="Desired ECS tasks decrease: ${raw_delta}"
fi

# BEGIN - Print report
echo ""
echo "${main_header}"
echo "=============================="

echo "- Target ECS Service: ${service}"
echo "- Target ECS Cluster: ${cluster}"
echo "- Target Autoscaling Group: ${asg}"
echo "- Current ECS service task count: ${current_ecs_count}"
echo "- Current ECS cluster total task count: ${total_running_task_count}"
echo "- Current ASG MinSize: ${curr_asg_min_size}"
echo "- Current ASG MaxSize: ${curr_asg_max_size}"
echo "- Current ASG DesiredCapacity: ${curr_asg_desired_capacity}"
echo "- ${requested_op}"
if [ "${warn_no_asg_adjustment}" = true ]; then
  echo ""
  echo "** Warning! Current ASG capacity is sufficient and would not be updated **"
fi

echo ""
echo "${updates_header}"
echo "===================================="

echo "- New ECS service count: ${new_ecs_count}"

if ! [ "${warn_no_asg_adjustment}" = true ]; then
  echo "- New ASG MinSize: ${new_asg_min_size}"
  echo "- New ASG MaxSize: ${new_asg_max_size}"
  echo "- New ASG Desired Capacity: ${new_asg_desired_capacity}"
fi


if ! [ "${report_only}" = true ]; then
  echo ""
  echo "- Updates complete!"
fi
echo ""
#msg "- arguments: ${args[*]-}"
