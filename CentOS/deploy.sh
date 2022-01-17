#!/bin/bash

TARGET=$1

. $TARGET/private.sh

# Can be validate or create
ACTION=${2-validate}

echo $ACTION

az deployment group $ACTION --name azure-slurm-test --resource-group $RG --template-file azuredeploy.json --parameters $TARGET/azuredeploy.parameters.json
