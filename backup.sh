#!/bin/sh

BACKUP_DESCRIPTION=$(date "+%Y%m%d%H%M%S")

# Error Codes
ebase=20
eusage=$((ebase+1))
eaccreate=$((ebase+2))
eaclist=$((ebase+3))
eacdestroy=$((ebase+4))

astra_pgbackrest() {
  app=$1
  pgbackrest_repo=$2
  echo "--> running pgbackrest"

  #For now, just sleep a few minutes so I can exec to the pod and poke around
  sleep 1800
  #Do the pgbackrest stuff here...

  echo "--> pgbackrest completed successfully"
}

astra_create_backup() {
  app=$1
  echo "--> creating astra control backup"
  actoolkit create backup ${app} cron-${BACKUP_DESCRIPTION} -t 60
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
app_id=$1
backups_to_keep=$2
pgbackrest_repo=$3
if [ -z "${app_id}" ] || [ -z ${backups_to_keep} ] || [ -z ${pgbackrest_repo} ]; then
  echo "Usage: $0 <app_id> <backups_to_keep> <pgbackrest_repo>"
  exit ${eusage}
fi

astra_pgbackrest ${app_id} ${pgbackrest_repo}
astra_create_backup ${app_id}
astra_delete_backups ${app_id} ${backups_to_keep}
