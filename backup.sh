#!/bin/sh

# This variable is used for ServiceNow event creation assignment group
SUPPORT_GROUP_ALIAS="IaaS Storage.AG"
SUPPORT_GROUP_ID="8ab19504132f1a002780d0528144b0db"

# This variable is used for uniqueness across backup names, optionally change to a more preferred format
BACKUP_DESCRIPTION=$(date "+%Y%m%d%H%M%S")

# Need a global variable for wait_pgbackrest function.  One of the params contains ':' and does not
# play well with a subshell invocation
PGBACKREST_RES=1

# Change as needed for difference stanza name, repository #, etc.  This is the filter used to determine
# if the pgbackrest commnad has completed
PGBACKREST_EXP_CMD="--stanza=db --repo=1 --type=incr"

# Error Codes
ebase=20
eusage=$((ebase+1))
epgannotation=$((ebase+2))
epgbrtimeout=$((ebase+3))
eaccreate=$((ebase+4))
eaclist=$((ebase+5))
eacdestroy=$((ebase+6))
esnowticket=$((ebase+7))

file_sn_ticket() {
    errmsg=$1
    curl "https://${snow_instance}/api/global/em/jsonv2" \
        --request POST \
        --header "Accept:application/json" \
        --header "Content-Type:application/json" \
        --user "${snow_username}":"${snow_password}" \
        --data @- << EOF
{
    "records": [
        {
            "source": "Instance Webhook",
            "resource": "${customer_name}",
            "node": "${cluster_name}",
            "type":"Astra Disaster Recovery Issue",
            "severity":"3",
            "description":"${errmsg}",
            "additional_info": "{
                \"sn_ci_identifier\": \"${cluster_name}\",
                \"sn_ci_type\": \"Kubernetes Cluster\",
                \"supportGroupId\": \"${SUPPORT_GROUP_ID}\",
                \"supportGroupAlias\": \"${SUPPORT_GROUP_ALIAS}\"
            }"
        }
    ]
}
EOF
    rc=$?
    if [ ${rc} -ne 0 ] ; then
        echo "--> Error creating ServiceNow ticket with error message: ${errmsg}"
        exit ${esnowticket}
    fi
}

pgbackrest_backup_annotation() {
    ns=$1
    db=$2
    kubectl get --namespace ${ns} postgrescluster/${db} \
        --output "go-template={{ index .metadata.annotations \"postgres-operator.crunchydata.com/pgbackrest-backup\" }}"
}

wait_pgbackrest() {
    ns=$1
    curr_anno=$2
    timeout=$3
    pgbackrest_repo=$4
    db=$5
    sleep_time=5

    # timeout is in minutes, sleep time in seconds.
    retries_per_min=`expr 60 / ${sleep_time}`
    retries=`expr ${timeout} \* ${retries_per_min}`

    i=1
    while [ ${i} -le ${retries} ]; do
	backup_cmd=""
	backup_cmd=$(
	    kubectl get pods --namespace ${ns} \
		    -o jsonpath="{.items[?(@.metadata.annotations.postgres-operator\.crunchydata\.com/pgbackrest-backup==\"${curr_anno}\")].spec.containers[*].env[?(@.name=='COMMAND_OPTS')].value}" \
		    --selector "
		    postgres-operator.crunchydata.com/cluster=${db},
		    postgres-operator.crunchydata.com/pgbackrest-backup=manual,
		    postgres-operator.crunchydata.com/pgbackrest-repo=${pgbackrest_repo}" \
			--field-selector 'status.phase=Succeeded'
		  )

	if [[ -n "${backup_cmd}" && "${backup_cmd}" == "${PGBACKREST_EXP_CMD}" ]]; then
	    echo "     Found backup command and it matched expected: ${PGBACKREST_EXP_CMD}"
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
    backup_cmd="kubectl pgo --namespace ${ns} backup ${db} --repoName=\"${pgbackrest_repo}\" --options=\"--type=incr\""

    echo "--> running pgbackrest"

    prior=$(pgbackrest_backup_annotation ${ns} ${db})
    # Assumption is that the first full backup has already been done - all automated backups will be incremental
    result=$(${backup_cmd})
    # It's possible there's an annotation conflict, this happens on restore.  If
    # we see the word 'conflict' in the result, remove it and try again
    for w in $result; do
	if [ "$w" = "conflict" ] || [ "$w" = "conflicts" ]; then
	    echo "Found annotation conflict, removing pgbackrest annotation"
	    result=$("kubectl annotate --namespace ${ns} postgrescluster/${db} postgres-operator.crunchydata.com/pgbackrest-backup-")
	    if [ $? != 0 ]; then
		ERR="Error removing pgbackrest annotation: ${result}"
		echo ${ERR}
		file_sn_ticket ${ERR}
		exit ${epgannotation}
	    fi

	    # With the annotation removed, we need to run the backup command again
	    echo "--> running pgbackrest after removing annotation"
	    result=$(${backup_cmd})
	fi
    done

    current=$(pgbackrest_backup_annotation ${ns} ${db})

    if [ "${current}" = "${prior}" ]; then
        ERR="Expected annotation to change when executing pgbackrest, got ${current}"
        echo ${ERR}
        file_sn_ticket ${ERR}
        exit ${epgannotation}
    fi

    # Now we need to wait until the pgbackrest pod is complete or error (timeout possibly)
    rc=1
    wait_pgbackrest ${ns} "${current}" ${pgbackrest_timeout} ${pgbackrest_repo} ${db}
    # Using the global varaible modified in wait_pgbackrest - see comment at top of script
    if [ ${PGBACKREST_RES} -ne 0 ]; then
        ERR="pgbackrest job did not complete successfully, either timed out or ended in error"
        echo ${ERR}
        file_sn_ticket $ERR
        exit ${epgbrtimeout}
    fi
    
    echo "--> pgbackrest completed successfully"
}

astra_create_backup() {
    app=$1
    astra_backup_poll_interval=$2
    echo "--> creating astra control backup"
    actoolkit create backup ${app} cron-${BACKUP_DESCRIPTION} -t ${astra_backup_poll_interval}
    rc=$?
    if [ ${rc} -ne 0 ] ; then
        ERR="error creating astra control backup cron-${BACKUP_DESCRIPTION} for ${app}"
        file_sn_ticket $ERR
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
    ERR="error running list backups for ${app}"
    file_sn_ticket $ERR
    exit ${eaclist}
  fi
  num_backups=$(echo $backup_json | jq  -r '.items[] | select(.state=="completed") | .id' | wc -l)
  
  while [ ${num_backups} -gt ${backups_keep} ] ; do

    echo "--> backups found: ${num_backups} is greater than backups to keep: ${backups_keep}"
    oldest_backup=$(echo ${backup_json} | jq '.items[] | select(.state=="completed")' | jq -s | jq -r 'min_by(.metadata.creationTimestamp) | .id')
    actoolkit destroy backup ${app} ${oldest_backup}
    rc=$?
    if [ ${rc} -ne 0 ] ; then
      ERR="error running destroy backup ${app} ${oldest_backup}"
      file_sn_ticket $ERR
      exit ${eacdestroy}
    fi

    sleep 120
    echo "--> checking number of astra control backups"
    backup_json=$(actoolkit -o json list backups --app ${app})
    rc=$?
    if [ ${rc} -ne 0 ] ; then
      ERR="error running list backups for ${app}"
      file_sn_ticket $ERR
      exit ${eaclist}
    fi
    num_backups=$(echo $backup_json | jq  -r '.items[] | select(.state=="completed") | .id' | wc -l)
  done

  echo "astra control backups at ${num_backups}"
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
astra_backup_poll_interval=$7
if [ -z ${namespace} ] || [ -z ${dbname} ] || [ -z ${app_id} ] || [ -z ${backups_to_keep} ] || [ -z ${pgbackrest_repo} ] || [ -z ${pgbackrest_timeout} ] || [ -z ${astra_backup_poll_interval} ]; then
    echo "Usage: $0 <namespace> <db_name> <app_id> <backups_to_keep> <pgbackrest_repo> <pgbackrest_timeout> <astra_backup_poll_interval>"
    exit ${eusage}
fi

astra_pgbackrest "${namespace}" "${dbname}" "${pgbackrest_repo}" ${pgbackrest_timeout}
astra_create_backup ${app_id} ${astra_backup_poll_interval}
astra_delete_backups ${app_id} ${backups_to_keep}
