#!/bin/bash
/usr/sbin/sshd -D &
echo main node: ${AWS_BATCH_JOB_MAIN_NODE_INDEX}
echo this node: ${AWS_BATCH_JOB_NODE_INDEX}
echo Downloading problem from S3: ${COMP_S3_PROBLEM_PATH}

if [ -z "$1" ]
then
  CNF=/CnC/formula.cnf
  aws s3 cp s3://${S3_BKT}/${COMP_S3_PROBLEM_PATH} $CNF
  DIR=/CnC
else
  CNF=$1
  DIR=.
fi

# check if input file exists, otherwise terminate
if [ ! -f "$CNF" ]; then echo "c ERROR formula does not exit"; exit 1; fi


BASENAME="${0##*/}"
OUT=/tmp

log () {
  echo "${BASENAME} - ${1}"
}
HOST_FILE_PATH="/tmp/hostfile"

# Set child by default switch to main if on main node container
NODE_TYPE="child"
if [ "${AWS_BATCH_JOB_MAIN_NODE_INDEX}" == "${AWS_BATCH_JOB_NODE_INDEX}" ]; then
  log "Running synchronize as the main node"
  NODE_TYPE="main"
fi


# wait for all nodes to report
wait_for_nodes () {
  log "Running as master node"

  touch $HOST_FILE_PATH
  ip=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)

  availablecores=$(nproc)
  log "master details -> $ip:$availablecores"
  echo "$ip slots=$availablecores" >> $HOST_FILE_PATH
  lines=$(ls -dq /tmp/hostfile* | wc -l)
  while [ "${AWS_BATCH_JOB_NUM_NODES}" -gt "${lines}" ]
  do
    cat $HOST_FILE_PATH
    lines=$(ls -dq /tmp/hostfile* | wc -l)

    log "$lines out of $AWS_BATCH_JOB_NUM_NODES nodes joined, check again in 1 second"
    sleep 1
#    lines=$(sort $HOST_FILE_PATH|uniq|wc -l)
  done

  # All of the hosts report their IP and number of processors. Combine all these
  # into one file with the following script:
  python supervised-scripts/make_combined_hostfile.py ${ip}
  $DIR/march_cu/march_cu $CNF -o $OUT/cubes$$ -d 15

  for (( NODE_NUM=0; NODE_NUM<${AWS_BATCH_JOB_NUM_NODES}; NODE_NUM++ ))
  do
    echo "p inccnf" > $OUT/formula$$-$NODE_NUM.icnf
    cat $CNF | grep -v c >> $OUT/formula$$-$NODE_NUM.icnf
    awk 'NR % '${AWS_BATCH_JOB_NUM_NODES}' == '$NODE_NUM'' $OUT/cubes$$ >> $OUT/formula$$-$NODE_NUM.icnf
    echo $OUT/formula$$-$NODE_NUM.icnf
    let "LINE_NUM=$NODE_NUM + 1"
    current_ip=$(cat combined_hostfile | head -$LINE_NUM | tail -1)
    echo $current_ip
    scp $OUT/formula$$-$NODE_NUM.icnf $current_ip:~/formula.icnf
  done


  # REPLACE THE FOLLOWING LINE WITH YOUR PARTICULAR SOLVER
#  time mpirun --allow-run-as-root -np ${NUM_PROCESSES} --hostfile combined_hostfile /hordesat/hordesat supervised-scripts/test.cnf
}

# Fetch and run a script
report_to_master () {
  # get own ip and num cpus
  #
  ip=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)


  availablecores=$(nproc)

  log "I am a child node -> $ip:$availablecores, reporting to the master node -> ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}"

  echo "$ip slots=$availablecores" >> $HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX}
  ping -c 3 ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}
  until scp $HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX} ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}:$HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX}
  do
    echo "Sleeping 5 seconds and trying again"
  done
  log "done! goodbye"
  ps -ef | grep sshd
  tail -f /dev/null
}

##
#
# Main - dispatch user request to appropriate function
log $NODE_TYPE
case $NODE_TYPE in
  main)
    wait_for_nodes "${@}"
    ;;

  child)
    report_to_master "${@}"
    ;;

  *)
    log $NODE_TYPE
    usage "Could not determine node type. Expected (main/child)"
    ;;
esac




#####################

#PAR=${NUM_PROCESSES}
#OUT=/tmp
#
#if [ -z "$PAR" ]; then PAR=4; fi
#
#echo $PAR
#
#
#rm -f $OUT/output*.txt
#touch $OUT/output.txt
#
#$DIR/march_cu/march_cu $CNF -o $OUT/cubes$$ -d 15
## $DIR/march_cu/march_cu $CNF -o $OUT/cubes$$ $2 $3 $4 $5 $6 $7 $8 $9
#
#OLD=-1
#FLAG=1
#while [ "$FLAG" == "1" ]
#do
##  cat $OUT/output*.txt | grep "SAT" | awk '{print $1}' | sort | uniq -c | tr "\n" "\t";
#
#  SAT=`cat $OUT/output*.txt | grep "^SAT" | awk '{print $1}' | uniq`
#  if [ "$SAT" == "SAT" ]; then echo "c DONE: ONE JOB SAT"; pkill -TERM -P $$; FLAG=0; fi
#
#  UNSAT=`cat $OUT/output*.txt | grep "^UNSAT" | wc |awk '{print $1}'`
#  if [ "$OLD" -ne "$UNSAT" ]; then echo; echo "c progress: "$UNSAT" UNSAT out of "$PAR; OLD=$UNSAT; fi
#  if [ "$UNSAT" == "$PAR" ]; then echo "c DONE: ALL JOBS UNSAT"; pkill -TERM -P $$; FLAG=0; break; fi
#  ALIVE=`ps $$ | wc | awk '{print $1}'`
#  if [ "$ALIVE" == "1" ]; then echo "c PARENT TERMINATED"; pkill -TERM -P $$; FLAG=0; break; fi
#  if [ "$FLAG"  == "1" ]; then sleep 1; fi
#done &
#
#for (( CORE=0; CORE<$PAR; CORE++ ))
#do
#  echo "p inccnf" > $OUT/formula$$-$CORE.icnf
#  cat $CNF | grep -v c >> $OUT/formula$$-$CORE.icnf
#  awk 'NR % '$PAR' == '$CORE'' $OUT/cubes$$ >> $OUT/formula$$-$CORE.icnf
#  $DIR/iglucose/core/iglucose $OUT/formula$$-$CORE.icnf $OUT/output-$CORE.txt -verb=0 &
#done
#wait
#
#rm $OUT/cubes$$
#for (( CORE=0; CORE<$PAR; CORE++ ))
#do
#  rm $OUT/formula$$-$CORE.icnf
#done
