#!/bin/bash

# The currently authenticated user gets admin rights to all machines
username=$(az account show --query user.name --output tsv)
vm1=$(az vm show --resource-group $RG --name master --query id -o tsv)
vm2=$(az vm show --resource-group $RG --name worker0 --query id -o tsv)
vm3=$(az vm show --resource-group $RG --name worker1 --query id -o tsv)

for vm in $vm1 $vm2 $vm3;do
  az role assignment create \
      --output yaml \
      --role "Virtual Machine Administrator Login" \
      --assignee $username \
      --scope $vm
done

# Other users get rights to the master node
for user in $NORMALUSER; do
  az role assignment create \
      --output yaml \
      --role "Virtual Machine User Login" \
      --assignee $user \
      --scope $vm1
done
