# Kubernetes CronJob-based Astra Control Backup

This repo details utilizing Kubernetes CronJobs to initiate Astra Control application backups, in addition to external services associated with said application.

## Secret Creation

In order to initiate application backups against Astra Control, our Kubernetes CronJob must have an appropriate access information and privileges mounted to the pod.  This example makes use of the [Astra Control SDK](https://github.com/NetApp/netapp-astra-toolkits), so a `config.yaml` file is needed which contains several components.

To create this file, run the following commands, but be sure to substitute in your Astra Control account ID, [API authorization token](https://docs.netapp.com/us-en/astra-automation/get-started/get_api_token.html#create-an-astra-api-token), and project name.  If you’re not sure of these values, additional information can be found in the [authentication section of the main SDK readme](https://github.com/NetApp/netapp-astra-toolkits/README.md#authentication) page on GitHub.

```text
API_TOKEN=NL1bSP5712pFCUvoBUOi2JX4xUKVVtHpW6fJMo0bRa8=
ACCOUNT_ID=12345678-abcd-4efg-1234-567890abcdef
ASTRA_PROJECT=astra.netapp.io
cat <<EOF > config.yaml
headers:
  Authorization: Bearer $API_TOKEN
uid: $ACCOUNT_ID
astra_project: $ASTRA_PROJECT
EOF
```

If done correctly, your config.yaml file should look like this:

```text
$ cat config.yaml 
headers:
  Authorization: Bearer NL1bSP5712pFCUvoBUOi2JX4xUKVVtHpW6fJMo0bRa8=
uid: 12345678-abcd-4efg-1234-567890abcdef
astra_project: astra.netapp.io
```

Next, apply your secret to the namespace of the application that will be protected:

```text
NAMESPACE=wordpress
kubectl -n $NAMESPACE create secret generic astra-control-config --from-file=config.yaml
```

## CronJob Creation

To apply the Kubernetes CronJob, run the following command:

```text
kubectl -n $NAMESPACE apply -f cron.yaml
```

## CronJob Verification

To view the status of the CronJob, run the following command:

```text
kubectl -n $NAMESPACE get cronjobs
```

In this example, the job has yet to execute:

```text
$ kubectl -n $NAMESPACE get cronjobs
NAME              SCHEDULE       SUSPEND   ACTIVE   LAST SCHEDULE   AGE
astra-pg-backup   */10 * * * *   False     0        <none>          78s
```
