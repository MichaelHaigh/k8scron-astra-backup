#!/bin/sh

BACKUP_DESCRIPTION=$(date "+%Y%m%d%H%M%S")
# Need a global variable for wait_pgbackrest function.  One of the params contains ':' and does not
# play well with a subshell invocation
PGBACKREST_RES=1

# Error Codes
ebase=20
eusage=$((ebase+1))
eaccreate=$((ebase+2))
eaclist=$((ebase+3))
eacdestroy=$((ebase+4))

file_sn_ticket() {
    errmsg=$1

    # Do what's needed to file SN ticket

}

pgbackrest_backup_annotation() {
    ns=$1
    db=$2
    kubectl get --namespace ${ns} postgrescluster/${db} \
        --output 'go-template={{ index .metadata.annotations "postgres-operator.crunchydata.com/pgbackrest-backup" }}'
}

wait_pgbackrest() {
    curr_anno=$1
    timeout=$2
    pgbackrest_repo=$3
    db=$4
    sleep_time=5

    # timeout is in minutes, sleep time in seconds.
    retries_per_min=`expr 60 / ${sleep_time}`
    retries=`expr ${timeout} \* ${retries_per_min}`

    i=1
    while [ ${i} -le ${retries} ]; do
	backup_cmd=""
	backup_cmd=$(
	    kubectl get pods --namespace postgres-operator \
		    -o jsonpath="{.items[?(@.metadata.annotations.postgres-operator\.crunchydata\.com/pgbackrest-backup==\"${curr_anno}\")].spec.containers[*].env[?(@.name=='COMMAND_OPTS')].value}" \
		    --selector "
		    postgres-operator.crunchydata.com/cluster=${db},
		    postgres-operator.crunchydata.com/pgbackrest-backup=manual,
		    postgres-operator.crunchydata.com/pgbackrest-repo=${pgbackrest_repo}" \
			--field-selector 'status.phase=Succeeded'
		  )

	if [[ -n "${backup_cmd}" && "${backup_cmd}" == "--stanza=db --repo=1 --type=incr" ]]; then
	    echo "Found backup command and it matched expected"
	    PGBACKREST_RES=0
	    return ${PGBACKREST_RES}
	fi
	echo "     Waiting for pgbackrest backup to complete..."
	sleep ${sleep_time}
	i=$(( ${i} + 1 ))
    done

    # Return 1 if timeout exceeded and pgbackrest pod was not successful
    PGBACKREST_RES=1
    return ${PGBACKREST_RES}
}

astra_pgbackrest() {
    ns=$1
    db=$2
    pgbackrest_repo=$3
    pgbackrest_timeout=$4

    echo "--> running pgbackrest"

    prior=$(pgbackrest_backup_annotation ${ns} ${db})
    # Assumption is that the first full backup has already been done - all automated backups will be incremental
    result=$(kubectl pgo --namespace ${ns} backup ${db} --repoName="${pgbackrest_repo}" --options="--type=incr")
    current=$(pgbackrest_backup_annotation $ns $db)

    if [ "${current}" = "${prior}" ]; then
	ERR="Expected annotation to change when executing pgbackrest, got ${current}"
	echo ${ERR}
	file_sn_ticket ${ERR}
	exit 1
    fi

    # Now we need to wait until the pgbackrest pod is complete or error (timeout possibly)
    rc=1
    wait_pgbackrest "${current}" ${pgbackrest_timeout} ${pgbackrest_repo} ${db}
    # Using the global varaible modified in wait_pgbackrest - see comment at top of script
    if [ ${PGBACKREST_RES} -ne 0 ]; then
	ERR="pgbackrest job did not complete successfully, either timed out or ended in error"
	echo ${ERR}
	file_sn_ticket $ERR
	exit 1
    fi
    
    echo "--> pgbackrest completed successfully"
}

astra_create_backup() {
    app=$1
    astra_backup_timeout=$2
    echo "--> creating astra control backup"
    actoolkit create backup ${app} cron-${BACKUP_DESCRIPTION} -t ${astra_backup_timeout}
    rc=$?
    if [ ${rc} -ne 0 ] ; then
	echo "--> error creating astra control backup cron-${BACKUP_DESCRIPTION} for ${app}"
	exit ${eaccreate}
    fi
}

astra_delete_backups() {
  app=$1
  backups_keep=$2

  echo "--> checking number of astra control backups"
  backup_json=$(actoolkit -o json list backups --app ${app})
  rc=$?
  if [ ${rc} -ne 0 ] ; then
    echo "--> error running list backups for ${app}"
    exit ${eaclist}
  fi
  num_backups=$(echo $backup_json | jq  -r '.items[].id' | wc -l)
  
  while [ ${num_backups} -gt ${backups_keep} ] ; do

    echo "--> backups found: ${num_backups} is greater than backups to keep: ${backups_keep}"
    oldest_backup=$(echo ${backup_json} | jq -r '.items | min_by(.metadata.creationTimestamp) | .id')
    actoolkit destroy backup ${app} ${oldest_backup}
    rc=$?
    if [ ${rc} -ne 0 ] ; then
      echo "--> error running destroy backup ${app} ${oldest_backup}"
      exit ${eacdestroy}
    fi

    sleep 120
    echo "--> checking number of astra control backups"
    backup_json=$(actoolkit -o json list backups --app ${app})
    rc=$?
    if [ ${rc} -ne 0 ] ; then
      echo "--> error running list backups for ${app}"
      exit ${eaclist}
    fi
    num_backups=$(echo $backup_json | jq  -r '.items[].id' | wc -l)
  done

  echo "--> backups at ${num_backups}"
}

#
# "main"
#
namespace=$1
dbname=$2
app_id=$3
backups_to_keep=$4
pgbackrest_repo=$5
pgbackrest_timeout=$6
astra_backup_timeout=$7
if [ -z ${namespace} ] || [ -z ${dbname} ] || [ -z ${app_id} ] || [ -z ${backups_to_keep} ] || [ -z ${pgbackrest_repo} ] || [ -z ${pgbackrest_timeout} ] || [ -z ${astra_backup_timeout} ]; then
    echo "Usage: $0 <namespace> <db_name> <app_id> <backups_to_keep> <pgbackrest_repo> <pgbackrest_timeout> <astra_backup_timeout>"
    exit ${eusage}
fi

astra_pgbackrest "${namespace}" "${dbname}" "${pgbackrest_repo}" ${pgbackrest_timeout}
astra_create_backup ${app_id} ${astra_backup_timeout}
astra_delete_backups ${app_id} ${backups_to_keep}
