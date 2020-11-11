#!/bin/bash

username=$(az account show --query user.name --output tsv)
vm1=$(az vm show --resource-group $RG --name master --query id -o tsv)
vm2=$(az vm show --resource-group $RG --name worker0 --query id -o tsv)
vm3=$(az vm show --resource-group $RG --name worker1 --query id -o tsv)

for vm in $vm1 $vm2 $vm3;do
  az role assignment create \
      --role "Virtual Machine Administrator Login" \
      --assignee $username \
      --scope $vm

  az role assignment create \
      --role "Virtual Machine User Login" \
      --assignee $NORMALUSER \
      --scope $vm
done
