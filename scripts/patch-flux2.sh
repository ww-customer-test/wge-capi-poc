

kubectl patch deployment -n wkp-workspaces source-controller      --type='json'   -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": [
   "--events-addr=http://notification-controller/",
    "--watch-all-namespaces=true",
        - --log-level=info
        - --log-encoding=json
        - --enable-leader-election
        - --storage-path=/data
        - --storage-adv-addr=source-controller.$(RUNTIME_NAMESPACE).svc.cluster.local.
]}]'