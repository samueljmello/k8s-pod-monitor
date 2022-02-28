#! /bin/bash
#
# Intent:
# To provide a continuous monitoring of pods within namespace(s) while running through
# uninstall/install of Helm charts.
#
# Assumptions (pre-reqs):
# - Kubectl configured to communicate with desired cluster
#

# echo blank line
ln() {
  echo ""
}
# function for printing usage
printusage()
{
      echo "usage: $0 [-n]"
      echo "-n  : Namespace regex to search. Must be a valid regex statement. Example: \"test1|test2\""
      echo "-p  : Optional pod regex to search. Must be a valid regex statement. Example: \"^test\""
      echo "-s  : Optional status regex to search. Must be a valid regex statement. Example: \"Backoff\""
      echo "-v  : Optional flag to show verbose warnings from the cluster."
      echo "-w  : Amount of seconds to wait before querying the K8s cluster again. Default is 5."
      echo "-h  : Display usage information"
}

# set default params
WAIT=5
FIRST_RUN=1
TRACK_WARNINGS=false
COUNT_CMD="wc -l | tr -d \"[:blank:]\""
NAMESPACEREGEX=".*"
PODREGEX=".*"
STATUSREGEX=".*"

# colors
GRAY="printf \"\033[90m\""
RED="printf \"\033[31m\""
WHITE="printf \"\033[97m\""
ORANGE="printf \"\033[48;5;208m\""
CLEAR="printf \"\033[0m\""
BGBLUE="printf \"\033[48;5;33m\""
BOLD="printf \"\033[1m\""

# if $COLUMNS is empty, populate it
if [[ -z "$COLUMNS" ]] ; then
  COLUMNS=$(tput cols)
else
  COLUMNS=${COLUMNS}
fi


# set up parameters
while getopts "n:p:s:w:hv" opt; do
  case $opt in
    n)
    if [[ ! -z "$OPTARG" ]]; then
      NAMESPACEREGEX="$OPTARG"
    fi
    ;;
    p) 
    if [[ ! -z "$OPTARG" ]]; then
      PODREGEX="$OPTARG"
    fi
    ;;
    s) 
    if [[ ! -z "$OPTARG" ]]; then
      STATUSREGEX="$OPTARG"
    fi
    ;;
    w) WAIT="$OPTARG"
    re='^[0-9]+$'
    if ! [[ ${WAIT} =~ ${re} ]] ; then
      echo "ERROR: You must provide a valid integer for the wait parameter."
      ln
      printusage
      ln
      exit 1
    fi
    ;;
    v)
    TRACK_WARNINGS=true
    ;;
    h)
    ln
    printusage
    ln
    exit 0
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ln
    printusage
    ln
    exit 1
    ;;
  esac
done

# print initial output
ln

echo "$(eval ${BGBLUE})$(eval ${WHITE})=============================$(eval ${CLEAR})"
echo "$(eval ${BGBLUE})$(eval ${WHITE})= K8s Namespace Pod Monitor =$(eval ${CLEAR})"
echo "$(eval ${BGBLUE})$(eval ${WHITE})=============================$(eval ${CLEAR})"

ln
echo -e "$(eval ${BOLD})Namespace Regex:$(eval ${CLEAR}) ${NAMESPACEREGEX}"
echo -e "$(eval ${BOLD})Pod Regex:$(eval ${CLEAR}) ${PODREGEX}"
echo -e "$(eval ${BOLD})Status Regex:$(eval ${CLEAR}) ${STATUSREGEX}"
ln
printf "Querying cluster..."

# create iterator
i=0

# update first run
LINES=0
EVENTS_COUNT=0
FILTER="awk '\$1 ~ \"${NAMESPACEREGEX}\"' | awk '\$2 ~ \"${PODREGEX}\"' | awk '\$4 ~ \"${STATUSREGEX}\"'"
SHORTEN="awk -v len=${COLUMNS} '{ if (length(\$0) > len) print substr(\$0, 1, len-3) \"...\"; else print; }'"

# keep doing until ctrl+c
while true; do

  # get all pods for the namespaces provided
  PODS=$(kubectl get po -A 2>&1)

  if [[ $TRACK_WARNINGS = true ]]; then
    # get any unique WARNING events
    EVENTS=$(kubectl get events -A --field-selector='type==Warning' 2>&1)
  fi

  # always clear the line
  echo -ne "\r\033[K";

  # when there are lines to clear, do so
  if [[ ${LINES} -gt 0 ]]; then
    for l in $(eval echo {1..$LINES}); do
      echo -ne "\r\033[1A\033[K";
    done
  else
    echo -ne "\r\033[K";
  fi

  # output pods header (lost when applying regex)
  eval ${BOLD}
  echo "${PODS}" | head -1
  eval ${CLEAR}

  # output pods, coloring specific words
  # "in-progress" words like "Pending" or "Init:0\1" should be dark grey (90m)
  # "bad status" words like "CrashLoopBackOff" should be red (31m)
  echo -e "${PODS}" \
    | eval ${FILTER} \
    | sed "s/Pending/$(eval $GRAY)Pending$(eval $CLEAR)/g" \
    | sed "s/ContainerCreating/$(eval $GRAY)ContainerCreating$(eval $CLEAR)/g" \
    | sed "s/Init:0\\\1/$(eval $GRAY)Init:0\\\1$(eval $CLEAR)/g" \
    | sed "s/Terminating/$(eval $GRAY)Terminating$(eval $CLEAR)/g" \
    | sed "s/CrashLoopBackOff/$(eval $RED)CrashLoopBackOff$(eval $CLEAR)/g" \
    | sed "s/NotReady/$(eval $RED)NotReady$(eval $CLEAR)/g" \
    | sed "s/ErrImagePull/$(eval $RED)ErrImagePull$(eval $CLEAR)/g" \
    | sed "s/ImagePullBackOff/$(eval $RED)ImagePullBackOff$(eval $CLEAR)/g" \
    | sed "s/RunContainerError/$(eval $RED)RunContainerError$(eval $CLEAR)/g" \
    | eval ${SHORTEN}

  ln


  BUFFER=6
  if [[ $TRACK_WARNINGS = false ]] || [[ -z "${EVENTS}" ]]; then
    BUFFER=$(expr ${BUFFER} - 3)
    EVENTLINES=0
  else
    # output events header (lost when applying regex)
    echo "$(eval ${BOLD})$(eval ${ORANGE})!! WARNINGS !!$(eval ${CLEAR}) $(eval ${GRAY})(truncated to terminal width)$(eval ${CLEAR})"
    
    ln
    echo "$(eval ${BOLD})${EVENTS}" | head -1
    eval ${CLEAR}
    
    # output events
    echo -e "${EVENTS}" \
      | awk '$1 ~ "'${NAMESPACEREGEX}'"' \
      | eval ${SHORTEN}

    EVENTLINES=$(echo "${EVENTS}" \
      | awk '$1 ~ "'${NAMESPACEREGEX}'"' \
      | awk '{print $0}' \
      | eval ${COUNT_CMD}
    )
  fi

  # count pods lines (must be post-clearing so that if the number of pods changes, it will clear
  # the appropriate amount).
  PODLINES=$(echo "${PODS}" \
    | eval ${FILTER} \
    | awk '{print $0}' \
    | eval ${COUNT_CMD})

  # add two additional buffer lines for below output
  LINES=$(expr ${PODLINES} + ${EVENTLINES} + ${BUFFER})

  ln
  echo -ne "\r\033[K";
  printf "$(eval ${GRAY})waiting for ${WAIT} second(s)... $(eval ${CLEAR})"
  # sleep for 5 seconds so we aren't constantly querying
  sleep ${WAIT}
  printf "$(eval ${GRAY})refreshing... $(eval ${CLEAR})"
  

done